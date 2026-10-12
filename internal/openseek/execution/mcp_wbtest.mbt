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
    // A file the engine cannot use is its own state, with the reason.
    let path = "\{dir}/mcp.json"
    guard connect_mcp(scope, workspace_root=dir, config_path=path).status()
      is ConfigRejected(path=missing, ..) else {
      fail("a missing file should be rejected")
    }
    assert_eq(missing, path)
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
