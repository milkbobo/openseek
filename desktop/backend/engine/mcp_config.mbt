// The MCP server configuration a conversation's engine runs with: one
// user-level file beside the global session store, in the de-facto
// `{"mcpServers": {...}}` shape the engine's `--mcp-config` decodes.
//
// The host is the file's only reader. It reads it before each prompt, gives a
// new engine its own copy of exactly what it read, and keeps a digest of that
// in the engine fingerprint, so an edit starts a new engine on the next
// prompt. The copy lasts only until the engine has loaded it. Because the engine never opens the user's file, what the host
// compared and what the engine loaded cannot differ. The host does not
// interpret the content — the engine connects the servers and reports what it
// could not use.

///|
/// Where the desktop looks for the user's MCP server configuration, or
/// `None` when the host has no home directory to look in. The user writes
/// the file by hand; the host only reads it.
fn mcp_config_path() -> @pathx.Absolute? {
  guard @workspaces.global_store_root() is Some(root) else { return None }
  Some(root.join("mcp.json"))
}

///|
/// What the host found in the configuration file. A file that exists but
/// cannot be read is its own observation, not an absent one: the engine is
/// still pointed at it and reports the failure.
priv enum McpConfigRevision {
  /// The file's text. It travels with the run config to the spawn, where it
  /// becomes the engine's copy; a live engine keeps only its digest.
  Text(String)
  ReadFailed(String)
}

///|
/// The user's MCP configuration as the host read it for one run.
priv struct McpConfig {
  path : @pathx.Absolute
  revision : McpConfigRevision
}

///|
/// Read the user's MCP configuration. An absent file is the ordinary
/// unconfigured state and names nothing, which leaves an
/// `OPENSEEK_MCP_CONFIG` inherited from the launching shell in effect exactly
/// as it is for the CLI. Called before the workspace lifecycle lock is taken,
/// never under it.
async fn resolved_mcp_config() -> McpConfig? {
  guard mcp_config_path() is Some(path) else { return None }
  let text = @fsx.read_text_if_exists(path.to_path()) catch {
    error => return Some({ path, revision: ReadFailed("\{error}"), })
  }
  guard text is Some(text) else { return None }
  Some({ path, revision: Text(text), })
}

///|
/// The fingerprint component for a run's MCP configuration: what a live
/// engine keeps of it. The tags keep a read failure from ever colliding with
/// a digest of the same text.
fn mcp_config_fingerprint(config : McpConfig?) -> String {
  guard config is Some({ path, revision, }) else { return "none" }
  match revision {
    Text(text) => {
      let digest = @crypto.bytes_to_hex_string(
        @crypto.sha256(@utf8.encode(text)),
      )
      "sha256\u{1}\{path}\u{1}\{digest}"
    }
    ReadFailed(error) => "unreadable\u{1}\{path}\u{1}\{error}"
  }
}

///|
/// What one engine was started with.
priv struct McpSnapshot {
  /// The path on the engine's command line, which is the path it reports.
  given : String
  /// The user's file, which is the path a person should be shown.
  source : String
  /// The fingerprint component of the content it holds.
  revision : String
}

///|
/// Where a conversation's engine finds its copy of the MCP configuration. The
/// session id becomes a file name here, so one that could name anything else
/// — a path separator, a dot segment — is refused before any path exists to
/// write to.
fn mcp_snapshot_path(
  runtime_dir : @pathx.Path,
  session : String,
) -> @pathx.Path raise EngineError {
  guard @session_store.safe_session_id(session) else {
    raise EngineError("invalid session id")
  }
  runtime_dir.join("mcp").join("\{session}.json")
}

///|
/// Prepare what a new engine for `session` is pointed at. With text in hand
/// and a runtime directory to keep it in, that is a private copy of the text:
/// the engine then loads exactly what the fingerprint describes, whatever
/// happens to the user's file meanwhile. The engine reads it once, as it
/// starts, and the caller discards it as soon as the engine says it has —
/// or when the start fails, or the engine's task ends without having said
/// so. The copy is rewritten for each new engine of the conversation, which
/// never overlaps the previous one's startup read. A file the host could not read has nothing to copy, and a
/// host without a runtime directory has nowhere to copy to; in both cases the
/// engine is pointed at the user's file and reports what it finds there.
async fn snapshot_mcp_config(
  config : McpConfig,
  runtime_dir : @pathx.Path?,
  session : String,
) -> McpSnapshot {
  let source = config.path.to_string()
  let revision = mcp_config_fingerprint(Some(config))
  guard (config.revision, runtime_dir) is (Text(text), Some(runtime_dir)) else {
    return { given: source, source, revision, }
  }
  let copy = mcp_snapshot_path(runtime_dir, session)
  // The configuration is where tokens live: the directory and the file are
  // the user's alone.
  @fs.mkdir(
    copy.dirname().to_string(),
    permission=0o700,
    recursive=true,
    allow_exist=true,
  )
  // Until this function returns, nobody else knows the file exists. If
  // making it is cut short — a full disk, the host shutting down between
  // creating the file and filling it — there is no record to remove it by,
  // so it is removed here.
  let mut written = false
  defer (if !written {
    @async.protect_from_cancel(() => {
      @fsx.remove_if_exists(copy) catch {
        _ => ()
      }
    })
  })
  @fs.write_file(
    copy.to_string(),
    text,
    create_mode=CreateOrTruncate,
    permission=0o600,
  )
  written = true
  { given: copy.to_string(), source, revision, }
}

///|
/// Remove the copy an engine was started with. Removing it again is nothing,
/// and the user's own file is never touched.
async fn McpSnapshot::discard(self : McpSnapshot) -> Unit {
  guard self.given != self.source else { return }
  @fsx.remove_if_exists(Path(self.given)) catch {
    _ => ()
  }
}

///|
/// The event as a person should read it: an engine started with a copy names
/// the copy, and the user's file is the one they can open and fix.
fn McpSnapshot::restore_path(
  self : McpSnapshot,
  event : @wire.Event,
) -> @wire.Event {
  fn shown(path : String) -> String {
    if path == self.given {
      self.source
    } else {
      path
    }
  }

  match event {
    McpConfigUnreadable(path~, error~) =>
      McpConfigUnreadable(path=shown(path), error~)
    McpConfigInvalid(path~, error~) =>
      McpConfigInvalid(path=shown(path), error~)
    McpStatus(status=ConfigRejected(path~, reason~)) =>
      McpStatus(status=ConfigRejected(path=shown(path), reason~))
    McpStatus(status=Configured(path~, servers~)) =>
      McpStatus(status=Configured(path=shown(path), servers~))
    other => other
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
  match engine.mcp_status {
    Some(status) => { config_path, engine: Running(status), }
    None => { config_path, engine: Connecting, }
  }
}

///|
async test "an absent MCP configuration names nothing; a present one is read" {
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
    fail("a present file should be resolved")
  }
  assert_eq(empty.path, path)
  assert_true(empty.revision is Text("{\"mcpServers\": {}}"))
  // Only the content decides: reading the same file twice is one revision,
  // and any edit is another.
  assert_eq(
    mcp_config_fingerprint(Some(empty)),
    mcp_config_fingerprint(resolved_mcp_config()),
  )
  @fsx.write_text(path.to_path(), "{\"mcpServers\": {\"a\": {}}}")
  let edited = resolved_mcp_config()
  assert_true(
    mcp_config_fingerprint(Some(empty)) != mcp_config_fingerprint(edited),
  )
  assert_true(mcp_config_fingerprint(None) != mcp_config_fingerprint(edited))
  // The fingerprint is a digest, not the text: it does not grow with the
  // file, and it is what a live engine keeps.
  assert_false(mcp_config_fingerprint(edited).contains("mcpServers"))
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
  // There is nothing to copy, so the engine is pointed at the file itself.
  let snapshot = snapshot_mcp_config(config, Some(root.join("runtime")), "s-1")
  assert_eq(snapshot.given, config.path.to_string())
  assert_eq(snapshot.source, snapshot.given)
  // Discarding that snapshot must leave the user's path alone.
  snapshot.discard()
  assert_true(@fs.kind(config.path.to_string()) is Directory)
}

///|
async test "a new engine is handed its own copy of the MCP configuration" {
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-snapshot-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  let path = root.join("home/.openseek/mcp.json").resolve()
  let config : McpConfig = { path, revision: Text("{\"mcpServers\": {}}"), }
  let runtime = root.join("runtime")
  let snapshot = snapshot_mcp_config(config, Some(runtime), "s-1")
  // The copy is per conversation, and holds exactly what the host read —
  // which is what the fingerprint describes.
  assert_eq(snapshot.given, runtime.join("mcp/s-1.json").to_string())
  assert_eq(snapshot.source, path.to_string())
  assert_eq(snapshot.revision, mcp_config_fingerprint(Some(config)))
  assert_eq(@fsx.read_text(Path(snapshot.given)), "{\"mcpServers\": {}}")
  // The conversation's next engine replaces the copy.
  let edited = snapshot_mcp_config(
    { ..config, revision: Text("{\"mcpServers\": {\"a\": {}}}"), },
    Some(runtime),
    "s-1",
  )
  assert_eq(edited.given, snapshot.given)
  assert_true(edited.revision != snapshot.revision)
  assert_eq(@fsx.read_text(Path(edited.given)), "{\"mcpServers\": {\"a\": {}}}")
  // A person is shown their own file, never the copy.
  @debug.assert_eq(
    edited.restore_path(McpConfigInvalid(path=edited.given, error="bad")),
    McpConfigInvalid(path=path.to_string(), error="bad"),
  )
  @debug.assert_eq(
    edited.restore_path(
      McpStatus(status=ConfigRejected(path=edited.given, reason="bad")),
    ),
    McpStatus(status=ConfigRejected(path=path.to_string(), reason="bad")),
  )
  @debug.assert_eq(
    edited.restore_path(
      McpStatus(status=Configured(path=edited.given, servers=[])),
    ),
    McpStatus(status=Configured(path=path.to_string(), servers=[])),
  )
  @debug.assert_eq(
    edited.restore_path(McpConnectFailed(server="a", error="x")),
    McpConnectFailed(server="a", error="x"),
  )
  // When the engine is gone, so is its copy.
  edited.discard()
  assert_true(@fsx.read_text_if_exists(Path(edited.given)) is None)
  // Without a runtime directory there is nowhere to keep a copy.
  let direct = snapshot_mcp_config(config, None, "s-1")
  assert_eq(direct.given, path.to_string())
}

///|
#cfg(not(platform="windows"))
async test "a broken MCP configuration is reported once, under the user's path" {
  let manager = new_engine_manager("/bin/sh")
  let emitted : Array[EngineEvent] = []
  let sink = EventSink(event => emitted.push(event))
  let source = "/home/.openseek/mcp.json"
  // What reached pages: each rejection's path, and each engine's last word.
  fn rejections() -> Array[String] {
    let paths : Array[String] = []
    for event in emitted {
      if event is StreamEvent({ event: McpConfigInvalid(path~, ..), .. }) {
        paths.push(path)
      }
    }
    paths
  }

  fn finished(session : String) -> Bool {
    emitted.any(event => {
      event is StreamEvent({ event: McpConnectFailed(server~, ..), .. }) &&
      server == session
    })
  }

  @async.with_task_group(group => {
    // Stands in for a serve engine that could not decode the copy it was
    // started with: it says so, naming the copy, then says one more thing.
    async fn start(session : String, revision : String) -> Unit {
      let script =
        #|printf '{"event":"mcp_config_invalid","path":"/runtime/mcp/%s.json","error":"bad"}\n' "$1"
        #|printf '{"event":"mcp_connect_failed","server":"%s","error":"marker"}\n' "$1"
        #|cat >/dev/null
      let (child_stdin, writer) = @process.write_to_process()
      let (reader, child_stdout) = @process.read_from_process()
      let process = @process.spawn(
        group,
        "/bin/sh",
        ["-c", script, "sh", session],
        stdin=child_stdin,
        stdout=child_stdout,
        no_wait=true,
      )
      let engine : ServeEngine = {
        ..test_serve_engine(
          session,
          writer,
          process,
          sink,
          phase=Idle(last_run=None),
        ),
        mcp: Some({ given: "/runtime/mcp/\{session}.json", source, revision, }),
      }
      group.spawn_bg(no_wait=true, allow_failure=true, () => {
        ignore(engine.consume(manager, reader))
      })
      @async.with_timeout(10000, () => {
        while !finished(session) {
          @async.sleep(20)
        }
      })
    }

    // Two conversations start engines on the same broken file. A person
    // hears it once, and is pointed at the file they can fix.
    start("s-1", "rev-a")
    @debug.assert_eq(rejections(), [source])
    start("s-2", "rev-a")
    @debug.assert_eq(rejections(), [source])
    // A different broken file is a new thing to say.
    start("s-3", "rev-b")
    @debug.assert_eq(rejections(), [source, source])
  })
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
    // The engine was started with a copy of the configuration, and names
    // that copy in what it reports.
    let engine : ServeEngine = {
      ..test_serve_engine(
        "s-live",
        writer,
        process,
        sink,
        phase=Idle(last_run=None),
      ),
      mcp: Some({
        given: "/p/mcp.json",
        source: "/home/.openseek/mcp.json",
        revision: "rev",
      }),
    }
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
      engine.run(manager, reader, stderr_task)
    })
    fn server_state() -> @wire.McpServerState? raise EngineError {
      match mcp_status(manager, { session: "s-live", }).engine {
        // What the host keeps names the user's file, not the copy.
        Running(Configured(path="/home/.openseek/mcp.json", servers=[server])) =>
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

///|
/// Test-only: a stand-in engine for `session`, started on `snapshot` with its
/// task running on `group`, whose child process runs `script`.
#cfg(not(platform="windows"))
async fn[G] start_stand_in_engine(
  group : @async.TaskGroup[G],
  manager : EngineManager,
  snapshot : McpSnapshot,
  session : String,
  script : String,
) -> Unit {
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
  let engine : ServeEngine = {
    ..test_serve_engine(
      session,
      writer,
      process,
      EventSink(_ => ()),
      phase=Idle(last_run=None),
    ),
    mcp: Some(snapshot),
  }
  let stderr_task = group.spawn(no_wait=true, () => "")
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    engine.run(manager, reader, stderr_task)
  })
}

///|
#cfg(not(platform="windows"))
async test "an engine's copy of the MCP configuration lasts until it has been loaded" {
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-copy-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  let manager = new_engine_manager("/bin/sh")
  let config : McpConfig = {
    path: root.join("home/.openseek/mcp.json").resolve(),
    revision: Text("{\"mcpServers\": {}}"),
  }
  let runtime = Some(root.join("runtime"))
  async fn copy_exists(snapshot : McpSnapshot) -> Bool {
    @fsx.read_text_if_exists(Path(snapshot.given)) is Some(_)
  }

  // The engine reads the copy once, as it starts, and says so. From then on
  // nothing needs it, however long the engine goes on running.
  let loaded = snapshot_mcp_config(config, runtime, "s-loaded")
  @async.with_task_group(group => {
    let script =
      #|printf '{"event":"mcp_tools_registered","servers":0,"tools":0,"names":[]}\n'
      #|cat >/dev/null
    start_stand_in_engine(group, manager, loaded, "s-loaded", script)
    @async.with_timeout(10000, () => {
      while copy_exists(loaded) {
        @async.sleep(20)
      }
    })
    group.return_immediately(())
  })
  // An engine that never gets that far — the host is shutting down, say, and
  // cancels the group its task runs in — leaves no copy behind either.
  let cancelled = snapshot_mcp_config(config, runtime, "s-cancelled")
  @async.with_task_group(group => {
    start_stand_in_engine(
      group, manager, cancelled, "s-cancelled", "cat >/dev/null",
    )
    @async.sleep(50)
    assert_true(copy_exists(cancelled))
    group.return_immediately(())
  })
  assert_false(copy_exists(cancelled))
  // Not even when the group ends before the engine's task has run at all.
  let unstarted = snapshot_mcp_config(config, runtime, "s-unstarted")
  @async.with_task_group(group => {
    start_stand_in_engine(
      group, manager, unstarted, "s-unstarted", "cat >/dev/null",
    )
    group.return_immediately(())
  })
  assert_false(copy_exists(unstarted))
}

///|
async test "a snapshot whose making is interrupted leaves nothing behind" {
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-partial-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  let config : McpConfig = {
    path: root.join("home/.openseek/mcp.json").resolve(),
    revision: Text("x".repeat(1024 * 1024)),
  }
  let runtime = root.join("runtime")
  // Where the cancellation lands is up to the scheduler: before the file is
  // written, in which case no record of it was ever returned, or after, in
  // which case the caller holds one. Neither may leave the file.
  for attempt in 0..<20 {
    let session = "s-\{attempt}"
    let copy = mcp_snapshot_path(runtime, session).to_string()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        // As the spawn path holds it: once there is a record, abandoning the
        // start discards what it names.
        let mut made : McpSnapshot? = None
        defer (if made is Some(snapshot) {
          @async.protect_from_cancel(() => snapshot.discard())
        })
        made = Some(snapshot_mcp_config(config, Some(runtime), session))
        @async.sleep(10000)
      })
      @async.with_timeout(10000, () => {
        while !@fs.exists(copy) {
          @async.sleep(1)
        }
      })
      group.return_immediately(())
    })
    assert_false(@fs.exists(copy))
  }
}

///|
async test "a session id that is not a file name gets no snapshot" {
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-session-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  let runtime = root.join("runtime")
  // What a path-like id would otherwise reach: a file beside the `mcp`
  // directory, which the host keeps other state in.
  let neighbour = runtime.join("engine-settings.json")
  @fsx.ensure_dir(runtime)
  @fsx.write_text(neighbour, "keep")
  let config : McpConfig = {
    path: root.join("home/.openseek/mcp.json").resolve(),
    revision: Text("{\"mcpServers\": {}}"),
  }
  for session in ["../engine-settings", "a/b", "a\\b", "..", "."] {
    let refused = try {
      ignore(snapshot_mcp_config(config, Some(runtime), session))
      false
    } catch {
      EngineError(_) => true
      _ => false
    }
    assert_true(refused)
  }
  assert_eq(@fsx.read_text(neighbour), "keep")
  assert_false(@fs.exists(runtime.join("mcp").to_string()))
}
