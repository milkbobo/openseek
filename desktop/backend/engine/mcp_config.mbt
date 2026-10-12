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
/// What a conversation's engine holds of its MCP servers right now. The host
/// keeps no connections of its own — each engine connects its servers when it
/// starts — so this forwards the question to the conversation's live engine
/// and returns its answer. A conversation with no engine running has nothing
/// to ask, which is its own answer rather than an error. Nothing is started:
/// the engine reads the state it already holds.
pub async fn mcp_status(
  manager : EngineManager,
  payload : @protocol.McpStatusPayload,
) -> @protocol.McpStatusReply {
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
  let request_id = @uuid.mint()
  guard engine.job_request(
      request_id,
      McpSnapshot(request_id~),
      subject="MCP status",
    )
    is McpSnapshot(status~, ..) else {
    raise EngineError(
      "the engine answered the MCP status request with another event",
    )
  }
  { config_path, engine: Running(status), }
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
async test "MCP status has nothing to ask when the conversation has no engine" {
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
async test "MCP status is the live engine's own answer" {
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
  // Stands in for a serve engine: answers each command line with a snapshot
  // carrying that line's request id, as the real one does.
  let script =
    #|while IFS= read -r line; do
    #|  id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
    #|  printf '{"event":"mcp_snapshot","request_id":"%s","status":{"config":"loaded","path":"/p/mcp.json","servers":[{"name":"a","transport":"stdio","target":"a","state":"failed","error":"spawn failed"}]}}\n' "$id"
    #|done
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
    // The two tasks a spawned engine runs for its life: the stdin writer and
    // the stdout pump.
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      engine.write_commands()
    })
    let stderr_task = group.spawn(no_wait=true, () => "")
    group.spawn_bg(no_wait=true, allow_failure=true, () => {
      engine.run(manager, reader, group, stderr_task)
    })
    let reply = mcp_status(manager, { session: "s-live", })
    guard reply.engine
      is Running(Configured(path="/p/mcp.json", servers=[server])) else {
      fail("the engine's snapshot should be forwarded")
    }
    assert_eq(server.name, "a")
    assert_true(server.state is Failed("spawn failed"))
    // The reply is private to the request: it is not a conversation event.
    assert_true(emitted.is_empty())
    // Another conversation is not answered by this one's engine.
    assert_true(
      mcp_status(manager, { session: "s-other", }).engine is NotRunning,
    )
  })
}
