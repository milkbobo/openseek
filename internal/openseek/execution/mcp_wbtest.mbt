///|
async test "the MCP registry says how the engine was configured and what came of it" {
  @async.with_task_group(group => {
    let scope = @agent_runtime.AgentTaskScope(group)
    let dir = @fs.tmpdir(prefix="openseek-mcp-registry-")
    defer @fs.rmdir(dir, recursive=true)
    // No `--mcp-config`: nothing was configured, and there are no tools.
    let unconfigured = connect_mcp(scope, workspace_root=dir)
    assert_true(unconfigured.status() is NotConfigured)
    assert_true(unconfigured.tools().is_empty())
    // A path with no file is not an error: there is nothing to load yet.
    let path = "\{dir}/mcp.json"
    guard connect_mcp(scope, workspace_root=dir, config_path=path).status()
      is ConfigAbsent(path=missing) else {
      fail("a missing file should be reported as absent")
    }
    assert_eq(missing, path)
    // A file the engine cannot use is its own state, with the reason.
    @fs.write_file(path, "{\"servers\": {}}", create_mode=CreateOrTruncate)
    guard connect_mcp(scope, workspace_root=dir, config_path=path).status()
      is ConfigRejected(reason~, ..) else {
      fail("a file without `mcpServers` should be rejected")
    }
    assert_true(reason.contains("mcpServers"))
    // A configured server that cannot start is listed with why, by its
    // command and never its arguments.
    @fs.write_file(
      path,
      (
        #|{"mcpServers": {"bad": {"command": "openseek-no-such-mcp-server-xyz", "args": ["--token", "secret"]}}}
      ),
      create_mode=CreateOrTruncate,
    )
    let loaded = connect_mcp(scope, workspace_root=dir, config_path=path)
    guard loaded.status() is Configured(path=config, servers=[server]) else {
      fail("the configured server should be listed")
    }
    assert_eq(config, path)
    assert_eq(server.name, "bad")
    assert_true(server.transport is Stdio)
    assert_eq(server.target, "openseek-no-such-mcp-server-xyz")
    assert_true(server.state is Failed(_))
    assert_true(loaded.tools().is_empty())
  })
}

///|
async test "the MCP registry tells its owner when a connected server is lost" {
  @async.with_task_group(group => {
    let scope = @agent_runtime.AgentTaskScope(group)
    let dir = @fs.tmpdir(prefix="openseek-mcp-registry-")
    defer @fs.rmdir(dir, recursive=true)
    // Offers one tool, then exits a moment later.
    let brief =
      #|read _
      #|printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25"}}\n'
      #|read _
      #|read _
      #|printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"ping"}]}}\n'
      #|sleep 1
    let config : Json = {
      "mcpServers": {
        "brief": { "command": "sh", "args": ["-c", Json(brief)] },
      },
    }
    let path = "\{dir}/mcp.json"
    @fs.write_file(path, config.stringify(), create_mode=CreateOrTruncate)
    let registry = connect_mcp(scope, workspace_root=dir, config_path=path)
    // Install, then read: a connection already gone never runs the handler.
    let closed : @async.Queue[Unit] = Queue(kind=Unbounded)
    registry.on_connection_closed(() => {
      ignore(closed.try_put(()) catch { _ => false })
    })
    guard registry.status() is Configured(servers=[server], ..) else {
      fail("the configured server should be listed")
    }
    match server.state {
      // Spawning is forbidden in this sandbox: skip.
      Failed(_) => {
        println("skipped: cannot spawn sh")
        return
      }
      Connected(tools) => {
        assert_eq([ for tool in tools => tool.name ], ["mcp__brief__ping"])
        @async.with_timeout(10000, () => closed.get())
      }
      _ => ()
    }
    // The tools stay registered with the model, so a lost server still lists
    // them — that is what tells it from one that never connected.
    guard registry.status()
      is Configured(servers=[{ state: Lost(tools), .. }], ..) else {
      fail("a server whose connection closed should be lost")
    }
    assert_eq([ for tool in tools => tool.name ], ["mcp__brief__ping"])
  })
}

///|
async test "reloading the MCP registry follows the file and keeps what did not change" {
  @async.with_task_group(group => {
    let scope = @agent_runtime.AgentTaskScope(group)
    let dir = @fs.tmpdir(prefix="openseek-mcp-reload-")
    defer @fs.rmdir(dir, recursive=true)
    // A server that answers for as long as it is asked: one `ping` tool.
    let serve =
      #|while IFS= read -r line; do
      #|  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      #|  case "$line" in
      #|    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25"}}\n' "$id" ;;
      #|    *'"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"ping"}]}}\n' "$id" ;;
      #|  esac
      #|done
    async fn write(servers : Map[String, Array[String]]) -> Unit {
      let listed : Map[String, Json] = Map([])
      for name, args in servers {
        listed[name] = { "command": "sh", "args": Json(["-c", serve, ..args]) }
      }
      @fs.write_file(
        "\{dir}/mcp.json",
        ({ "mcpServers": Json::object(listed) } : Json).stringify(),
        create_mode=CreateOrTruncate,
      )
    }

    fn names(tools : Array[@agent_tool.AgentToolDefinition]) -> Array[String] {
      [
        for tool in tools => tool.name
      ]
    }

    let path = "\{dir}/mcp.json"
    // The engine starts before anyone has written the file.
    let registry = connect_mcp(scope, workspace_root=dir, config_path=path)
    let closes = Ref(0)
    registry.on_connection_closed(() => closes.val += 1)
    assert_true(registry.status() is ConfigAbsent(_))
    assert_true(registry.reload(scope, workspace_root=dir) is None)
    // The file appears: its servers connect on the next reload.
    write({ "keep": [], "edit": [] })
    guard registry.reload(scope, workspace_root=dir) is Some(appeared) else {
      fail("a new file should be loaded")
    }
    guard registry.entries() is [keep, edit] else {
      fail("both servers should be listed")
    }
    if keep.connection is Failed(_) {
      // Spawning is forbidden in this sandbox: skip.
      println("skipped: cannot spawn sh")
      return
    }
    guard (keep.connection, edit.connection)
      is (Live(keep_client), Live(edit_client)) else {
      fail("both servers should be live")
    }
    assert_true(appeared.removed.is_empty())
    assert_eq(names(appeared.added), ["mcp__keep__ping", "mcp__edit__ping"])
    // Nothing changed in the file: nothing to do, nothing restarted.
    assert_true(registry.reload(scope, workspace_root=dir) is None)
    assert_eq(closes.val, 0)
    // One server is redefined. The other keeps its connection, and the swap
    // names every MCP tool because names are decided over the whole set.
    write({ "keep": [], "edit": ["v2"] })
    guard registry.reload(scope, workspace_root=dir) is Some(edited) else {
      fail("an edited file should be loaded")
    }
    assert_eq(edited.removed, ["mcp__keep__ping", "mcp__edit__ping"])
    assert_eq(names(edited.added), ["mcp__keep__ping", "mcp__edit__ping"])
    guard registry.entries()
      is [{ connection: Live(kept), .. }, { connection: Live(replaced), .. }] else {
      fail("both servers should still be live")
    }
    assert_true(physical_equal(kept, keep_client))
    assert_false(kept.is_closed())
    assert_false(physical_equal(replaced, edit_client))
    assert_true(edit_client.is_closed())
    // Letting the old connection go is the reload's own doing, not news.
    assert_eq(closes.val, 0)
    // A connection that carried over still says so when it goes by itself.
    kept.close()
    assert_eq(closes.val, 1)
    assert_true(
      registry.status()
      is Configured(
        servers=[{ state: Lost(_), .. }, { state: Connected(_), .. }],
        ..
      ),
    )
    // A file that stops being usable takes its servers with it, as it would
    // for an engine starting now.
    @fs.write_file(path, "{", create_mode=CreateOrTruncate)
    guard registry.reload(scope, workspace_root=dir) is Some(broken) else {
      fail("a broken file should be acted on")
    }
    assert_eq(broken.removed, ["mcp__keep__ping", "mcp__edit__ping"])
    assert_true(broken.added.is_empty())
    assert_true(registry.status() is ConfigRejected(_, ..))
    assert_true(kept.is_closed() && replaced.is_closed())
    assert_eq(closes.val, 1)
    // The same broken file is not reported again every turn.
    assert_true(registry.reload(scope, workspace_root=dir) is None)
    @fs.remove(path)
    assert_true(registry.reload(scope, workspace_root=dir) is Some(_))
    assert_true(registry.status() is ConfigAbsent(_))
    // An engine started without a configuration has no file to follow.
    let unconfigured = connect_mcp(scope, workspace_root=dir)
    write({ "keep": [] })
    assert_true(unconfigured.reload(scope, workspace_root=dir) is None)
  })
}
