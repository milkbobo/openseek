///|
test "the engine's MCP report decodes into per-server states" {
  // The exact shape `openseek mcp --format json` prints.
  let listed : Json = [
    {
      "name": "playwright",
      "transport": "stdio",
      "target": "npx",
      "state": "connected",
      "tools": [
        {
          "name": "mcp__playwright__browser_click",
          "description": "Perform click on a web page",
        },
      ],
    },
    {
      "name": "remote",
      "transport": "http",
      "target": "https://example.com/mcp",
      "state": "failed",
      "error": "connection refused",
    },
    {
      "name": "quiet",
      "transport": "stdio",
      "target": "quiet",
      "state": "no_tools",
    },
    {
      "name": "late",
      "transport": "stdio",
      "target": "late",
      "state": "skipped",
    },
  ]
  let servers = @protocol.McpServerStatus::from_report({ "servers": listed })
  @debug.assert_eq(servers.map(server => server.state), [
    Connected([
      {
        name: "mcp__playwright__browser_click",
        description: "Perform click on a web page",
      },
    ]),
    Failed("connection refused"),
    NoTools,
    Skipped,
  ])
  @debug.assert_eq(servers.map(server => server.transport), [
    Stdio,
    Http,
    Stdio,
    Stdio,
  ])
  // The reply forwards the engine's servers unchanged.
  let reply : @protocol.McpStatusReply = Configured(
    path="/home/.openseek/mcp.json",
    servers~,
  )
  let decoded : @protocol.McpStatusReply = @json.from_json(reply.to_json())
  @debug.assert_eq(decoded, reply)
  let expected : Json = {
    "config": "loaded",
    "path": "/home/.openseek/mcp.json",
    "servers": listed,
  }
  assert_true(reply.to_json() == expected)
}

///|
test "MCP status replies round-trip without servers" {
  let replies : Array[@protocol.McpStatusReply] = [
    NoConfig(path="/home/.openseek/mcp.json"),
    ConfigRejected(
      path="/home/.openseek/mcp.json",
      reason="configuration is missing an `mcpServers` object",
    ),
    Configured(path="/home/.openseek/mcp.json", servers=[]),
  ]
  for reply in replies {
    let decoded : @protocol.McpStatusReply = @json.from_json(reply.to_json())
    @debug.assert_eq(decoded, reply)
  }
}

///|
test "a malformed MCP server status is refused, not guessed" {
  fn refused(json : Json) -> Bool {
    let _ : @protocol.McpServerStatus = @json.from_json(json) catch {
      _ => return true
    }
    false
  }

  // A connected server always lists what it registered.
  assert_true(
    refused({
      "name": "a",
      "transport": "stdio",
      "target": "a",
      "state": "connected",
      "tools": [],
    }),
  )
  assert_true(
    refused({
      "name": "a",
      "transport": "stdio",
      "target": "a",
      "state": "failed",
    }),
  )
  assert_true(
    refused({
      "name": "a",
      "transport": "pipe",
      "target": "a",
      "state": "skipped",
    }),
  )
  assert_true(
    refused({ "name": "a", "transport": "stdio", "target": "a", "state": "up" }),
  )
}
