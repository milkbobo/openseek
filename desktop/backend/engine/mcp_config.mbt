// The MCP server configuration every serve engine is spawned with: one
// user-level file beside the global session store, in the de-facto
// `{"mcpServers": {...}}` shape the engine's `--mcp-config` decodes. The
// host never interprets it — the engine connects the servers and reports
// what it could not use — so the host's part is naming the file and noticing
// that it changed.

///|
/// Where the desktop looks for the user's MCP server configuration, or
/// `None` when the host has no home directory to look in. The user writes
/// the file by hand; the host only reads it.
fn mcp_config_path() -> @pathx.Absolute? {
  guard @workspaces.global_store_root() is Some(root) else { return None }
  Some(root.join("mcp.json"))
}

///|
/// What the host observed in the configuration file when it resolved a run's
/// config. A file that exists but cannot be read is its own observation, not
/// an absent one: the engine is still pointed at it and reports the failure.
priv enum McpConfigRevision {
  Text(String)
  ReadFailed(String)
}

///|
/// The MCP configuration file a serve engine is pointed at.
priv struct McpConfig {
  path : @pathx.Absolute
  // Pins the engine process to what the file held (see `engine_fingerprint`):
  // servers are connected once at engine startup, so an edit only takes
  // effect in a new process.
  revision : McpConfigRevision
}

///|
/// The configuration the next engine should load. An absent file is the
/// ordinary unconfigured state and names nothing, which leaves an
/// `OPENSEEK_MCP_CONFIG` inherited from the launching shell in effect exactly
/// as it is for the CLI.
async fn resolved_mcp_config() -> McpConfig? {
  guard mcp_config_path() is Some(path) else { return None }
  let text = @fsx.read_text_if_exists(path.to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    error => return Some({ path, revision: ReadFailed("\{error}"), })
  }
  guard text is Some(text) else { return None }
  Some({ path, revision: Text(text), })
}

///|
/// The fingerprint component for a run's MCP configuration. The tags keep a
/// read failure from ever colliding with file content of the same text.
fn mcp_config_fingerprint(config : McpConfig?) -> String {
  guard config is Some({ path, revision, }) else { return "none" }
  match revision {
    Text(text) => "text\u{1}\{path}\u{1}\{text}"
    ReadFailed(error) => "unreadable\u{1}\{path}\u{1}\{error}"
  }
}

///|
/// How long one status check may take. The engine connects the servers one
/// after another and bounds each on its own, so this only stops a check that
/// several unresponsive servers would otherwise stretch without limit.
const McpStatusTimeoutMs : Int = 120_000

///|
/// What the user's MCP configuration yields right now: the servers it lists
/// and, for each, the tools an engine would get from it or why it would get
/// none. The host decides only whether there is a usable configuration; the
/// connecting is the engine's own `mcp` command, run with the environment an
/// engine's servers see, so the answer is the one a conversation would get.
/// Stdio servers are started for the check and stopped when it returns.
pub async fn mcp_status(manager : EngineManager) -> @protocol.McpStatusReply {
  guard @home.dir() is Some(home) && mcp_config_path() is Some(config_path) else {
    raise EngineError(
      "there is no home directory to look for the MCP configuration in",
    )
  }
  let path = config_path.to_string()
  guard resolved_mcp_config() is Some(config) else { return NoConfig(path~) }
  let text = match config.revision {
    Text(text) => text
    ReadFailed(reason) => return ConfigRejected(path~, reason~)
  }
  // The engine's own decoder, so a file is rejected here exactly when an
  // engine would reject it.
  let servers = @mcpconfig.decode(@json.parse(text)) catch {
    error => return ConfigRejected(path~, reason="\{error}")
  }
  guard !servers.is_empty() else { return Configured(path~, servers=[]) }
  let env = @sys.get_env_vars()
  add_moonbit_path_for_native_engine(env, manager.engine, manager.runtime_dir)
  // Conversations run their servers in the project directory. A check has no
  // project, so the servers start in the user's home.
  let args = ["mcp", "--mcp-config=\{path}", "--format=json", "--dir=\{home}"]
  guard @async.with_timeout_opt(McpStatusTimeoutMs, () => {
      @processx.collect_output_no_stdin(
        manager.engine,
        args,
        extra_env=env,
        inherit_env=false,
      )
    })
    is Some((code, stdout, stderr)) else {
    raise EngineError("checking the MCP servers timed out")
  }
  guard code == 0 else {
    let detail = (stderr.text() catch { _ => "" }).trim().to_owned()
    raise EngineError(
      if detail.is_empty() {
        "the engine's MCP check exited with code \{code}"
      } else {
        detail
      },
    )
  }
  let servers = @protocol.McpServerStatus::from_report(
    @json.parse(stdout.text()),
  ) catch {
    error =>
      raise EngineError("the engine wrote a malformed MCP report: \{error}")
  }
  Configured(path~, servers~)
}

///|
async test "an absent MCP configuration names nothing; a present one pins its text" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var(test_home_env_name())
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-config-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  set_test_home(root.to_string())
  assert_true(resolved_mcp_config() is None)
  guard mcp_config_path() is Some(path) else {
    fail("a home directory should place the MCP configuration")
  }
  assert_eq(path.to_string(), root.join(".openseek/mcp.json").to_string())
  @fsx.ensure_dir(path.to_path().dirname())
  @fsx.write_text(path.to_path(), "{\"mcpServers\": {}}")
  guard resolved_mcp_config() is Some(empty) else {
    fail("an existing MCP configuration should be resolved")
  }
  assert_true(empty.path == path)
  assert_true(empty.revision is Text("{\"mcpServers\": {}}"))
  @fsx.write_text(
    path.to_path(),
    "{\"mcpServers\": {\"a\": {\"command\": \"a\"}}}",
  )
  let edited = resolved_mcp_config()
  assert_true(
    mcp_config_fingerprint(Some(empty)) != mcp_config_fingerprint(edited),
  )
  assert_true(mcp_config_fingerprint(None) != mcp_config_fingerprint(edited))
}

///|
async test "an unreadable MCP configuration is carried, not treated as absent" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var(test_home_env_name())
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-config-unreadable-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  set_test_home(root.to_string())
  // A directory where the file belongs exists but can never be read as one,
  // on every platform and regardless of the user's permissions.
  @fsx.ensure_dir(root.join(".openseek/mcp.json"))
  guard resolved_mcp_config() is Some(config) else {
    fail("a configuration that exists but cannot be read must not be dropped")
  }
  assert_true(config.revision is ReadFailed(_))
  assert_true(
    mcp_config_fingerprint(Some(config)) !=
    mcp_config_fingerprint(Some({ ..config, revision: Text(""), })),
  )
}

///|
async test "MCP status reads the configuration before it asks the engine" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var(test_home_env_name())
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-status-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  set_test_home(root.to_string())
  // None of these states has a server to connect to, so the engine — which
  // does not exist here — is never run.
  let manager = new_engine_manager(root.join("no-such-engine").to_string())
  let config = root.join(".openseek/mcp.json")
  assert_true(
    mcp_status(manager) is NoConfig(path~) && path == config.to_string(),
  )
  @fsx.ensure_dir(config.dirname())
  @fsx.write_text(config, "{\"mcpServers\": {}}")
  assert_true(mcp_status(manager) is Configured(servers=[], ..))
  @fsx.write_text(config, "not json")
  assert_true(mcp_status(manager) is ConfigRejected(..))
  @fsx.write_text(config, "{\"servers\": {}}")
  guard mcp_status(manager) is ConfigRejected(reason~, ..) else {
    fail("a file without `mcpServers` should be rejected")
  }
  assert_true(reason.contains("mcpServers"))
  // A file that exists and cannot be read is rejected, never "no config".
  @fs.remove(config.to_string())
  @fsx.ensure_dir(config)
  assert_true(mcp_status(manager) is ConfigRejected(..))
}

///|
#cfg(not(platform="windows"))
async test "MCP status forwards the engine's report and its failures" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var("HOME")
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-status-engine-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  @sys.set_env_var("HOME", root.join("home").to_string())
  let engine = root.join("bin/engine.sh")
  let runtime = root.join("runtime")
  prepare_fake_moonbit_seed(
    root.join("bin/toolchains/moonbit/macos-arm64"),
    version="0.10.0-test",
  )
  prepare_fake_bundled_moonbit_home(
    runtime.join("toolchains/moonbit/macos-arm64"),
    version="0.10.0-test",
  )
  let config = root.join("home/.openseek/mcp.json")
  @fsx.ensure_dir(config.dirname())
  @fsx.write_text(config, "{\"mcpServers\": {\"a\": {\"command\": \"a\"}}}")
  let manager = new_engine_manager(engine.to_string(), runtime_dir=runtime)
  let args_log = root.join("args")
  let report =
    #|{"servers":[{"name":"a","transport":"stdio","target":"a","state":"failed","error":"spawn failed"}]}
  @fs.write_file(
    engine.to_string(),
    "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\{args_log}'\nprintf '%s' '\{report}'\n",
    create_mode=CreateOrTruncate,
  )
  assert_eq(@process.run("chmod", ["+x", engine.to_string()]), 0)
  guard mcp_status(manager) is Configured(servers=[server], ..) else {
    fail("the engine's report should be forwarded")
  }
  assert_eq(server.name, "a")
  assert_true(server.state is Failed("spawn failed"))
  @debug.assert_eq(
    [..@fsx.read_text(args_log).trim().split("\n")].map(arg => arg.to_owned()),
    [
      "mcp",
      "--mcp-config=\{config}",
      "--format=json",
      "--dir=\{root.join("home")}",
    ],
  )
  // An engine that fails is a failed check, with the engine's own words —
  // not a rejected configuration and not an empty list.
  @fs.write_file(
    engine.to_string(),
    "#!/bin/sh\necho 'engine broke' >&2\nexit 3\n",
    create_mode=CreateOrTruncate,
  )
  let failure = try {
    ignore(mcp_status(manager))
    "no error"
  } catch {
    EngineError(detail) => detail
    error => "\{error}"
  }
  assert_eq(failure, "engine broke")
}
