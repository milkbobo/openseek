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
  /// The SHA-256 of the file's content, in hex. A live engine keeps its
  /// config for its whole life, so what is kept of the file must not grow
  /// with the file.
  Digest(String)
  ReadFailed(String)
}

///|
/// The revision of a file holding `text`.
fn McpConfigRevision::of_text(text : String) -> McpConfigRevision {
  Digest(@crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(text))))
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
  Some({ path, revision: McpConfigRevision::of_text(text), })
}

///|
/// The fingerprint component for a run's MCP configuration. The tags keep a
/// read failure from ever colliding with a digest of the same text.
fn mcp_config_fingerprint(config : McpConfig?) -> String {
  guard config is Some({ path, revision, }) else { return "none" }
  match revision {
    Digest(digest) => "sha256\u{1}\{path}\u{1}\{digest}"
    ReadFailed(error) => "unreadable\u{1}\{path}\u{1}\{error}"
  }
}

///|
/// What a conversation's engine holds of its MCP servers. The host keeps no
/// connections of its own — each engine connects its servers when it starts
/// and reports what came of it, then again whenever that changes — so this is
/// the conversation's live engine's latest report, as the host kept it. A
/// conversation with no engine running has none, and an engine that has not
/// reported yet is still connecting; both are answers, not errors. Nothing is
/// started and the engine is not asked.
pub fn mcp_status(
  manager : EngineManager,
  payload : @protocol.McpStatusPayload,
) -> @protocol.McpStatusReply raise EngineError {
  guard mcp_config_path() is Some(config_path) else {
    raise EngineError(
      "there is no home directory to look for the MCP configuration in",
    )
  }
  let config_path = config_path.to_string()
  guard manager.pump is Serving(sessions~) &&
    sessions.get(payload.session) is Some(slot) &&
    slot.live() is Some(engine) else {
    return { config_path, engine: NotRunning, }
  }
  match engine.mcp {
    Some(status) => { config_path, engine: Running(status), }
    None => { config_path, engine: Connecting, }
  }
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
  // What is kept of the file is a fixed-size digest of it, not its text.
  guard empty.revision is Digest(digest) else {
    fail("a readable file is observed by its digest")
  }
  assert_eq(digest.length(), 64)
  assert_true(
    mcp_config_fingerprint(Some(empty)) ==
    mcp_config_fingerprint(
      Some({
        ..empty,
        revision: McpConfigRevision::of_text("{\"mcpServers\": {}}"),
      }),
    ),
  )
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
    mcp_config_fingerprint(
      Some({ ..config, revision: McpConfigRevision::of_text(""), }),
    ),
  )
}

///|
async test "MCP status has nothing to report when the conversation has no engine" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var(test_home_env_name())
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-status-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  set_test_home(root.to_string())
  let manager = new_engine_manager("unused")
  // The host is not serving at all, then serving but not this conversation.
  let reply = mcp_status(manager, { session: "s-idle", })
  assert_true(reply.engine is NotRunning)
  assert_eq(reply.config_path, root.join(".openseek/mcp.json").to_string())
  manager.pump = Serving(sessions=Map([]))
  assert_true(mcp_status(manager, { session: "s-idle", }).engine is NotRunning)
}

///|
#cfg(not(platform="windows"))
async test "MCP status is the live engine's latest report" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var("HOME")
  defer restore_home_env(previous_home)
  let root = @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-status-engine-"))
  defer @fs.rmdir(root, recursive=true)
  @sys.set_env_var("HOME", root)
  let manager = new_engine_manager("/bin/sh")
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(event => emitted.push(event))
  // Stands in for a serve engine: reports its one server connected, then
  // lost a moment later, as the real one does when a server exits. Nothing
  // is ever written to it.
  let script =
    #|printf '{"event":"mcp_status","status":{"config":"loaded","path":"/p/mcp.json","servers":[{"name":"a","transport":"stdio","target":"a","state":"connected","tools":[{"name":"mcp__a__ping","description":"ping"}]}]}}\n'
    #|sleep 0.3
    #|printf '{"event":"mcp_status","status":{"config":"loaded","path":"/p/mcp.json","servers":[{"name":"a","transport":"stdio","target":"a","state":"lost","tools":[{"name":"mcp__a__ping","description":"ping"}]}]}}\n'
    #|cat >/dev/null
  @async.with_task_group(group => {
    let (child_stdin, writer) = @process.write_to_process()
    let (reader, child_stdout) = @process.read_from_process()
    let process = @process.spawn(
      group,
      "/bin/sh",
      ["-c", script],
      stdin=child_stdin,
      stdout=child_stdout,
      no_wait=true,
    )
    let engine = test_serve_engine(
      "s-live",
      writer,
      process,
      sink,
      phase=Idle(last_run=None),
    )
    let sessions : Map[String, SessionSlot] = Map([])
    slot_for(sessions, "s-live").engine = Some(engine)
    manager.pump = Serving(sessions~)
    // Nothing of the engine's output has been read yet: it is running and
    // has not reported, which is neither stopped nor an empty configuration.
    assert_true(
      mcp_status(manager, { session: "s-live", }).engine is Connecting,
    )
    let stderr_task = group.spawn(no_wait=true, () => "")
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      engine.run(manager, reader, group, stderr_task)
    })
    fn server_state() -> @wire.McpServerState? raise EngineError {
      match mcp_status(manager, { session: "s-live", }).engine {
        Running(Configured(path="/p/mcp.json", servers=[server])) =>
          Some(server.state)
        _ => None
      }
    }

    // Each report replaces the last, so the reply ends on the newest one.
    @async.with_timeout(10000, () => {
      while !(server_state() is Some(Lost(_))) {
        @async.sleep(20)
      }
    })
    // Both reports also went out to pages, in order: that is what tells a
    // page already showing the status to read it again.
    let reported : Array[@wire.McpServerState] = []
    for event in emitted {
      if event
        is StreamEvent(
          {
            session: "s-live",
            event: McpStatus(status=Configured(servers=[server], ..)),
            ..
          }
        ) {
        reported.push(server.state)
      }
    }
    assert_true(reported is [Connected(_), Lost(_)])
    // Another conversation is not answered by this one's engine.
    assert_true(
      mcp_status(manager, { session: "s-other", }).engine is NotRunning,
    )
  })
}
