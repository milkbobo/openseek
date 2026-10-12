///|
fn report_tool(name : String) -> @agent_tool.AgentToolDefinition {
  AgentToolDefinition(
    name~,
    description="does \{name}",
    schema=JsonSchema({ "type": "object" }),
    execute=Sync(_ => @agent_tool.respond("ok")),
  )
}

///|
test "the JSON report says what connecting each server yielded" {
  let stdio : @mcpconfig.McpServer = Stdio(
    name="local",
    command="npx",
    args=["--token", "secret"],
    env={},
  )
  let http : @mcpconfig.McpServer = Http(
    name="remote",
    url="https://user:secret@example.com/mcp?token=abc",
    headers={},
  )
  // Events are attributed by server name: another server's failure, and an
  // event that explains nothing, must not decide this server's state.
  let events : Array[@protocol.Event] = [
    McpConnectFailed(server="other", error="unrelated"),
    McpToolRenamed(from="a", to="a-2"),
    McpConnectFailed(server="remote", error="connection refused"),
  ]
  json_inspect(server_report(stdio, [report_tool("mcp__local__go")], events), content={
    "name": "local",
    "transport": "stdio",
    "target": "npx",
    "state": "connected",
    "tools": [
      { "name": "mcp__local__go", "description": "does mcp__local__go" },
    ],
  })
  // Credentials in the URL never reach the report.
  json_inspect(server_report(http, [], events), content={
    "name": "remote",
    "transport": "http",
    "target": "https://example.com/mcp",
    "state": "failed",
    "error": "connection refused",
  })
  json_inspect(
    server_report(stdio, [], [McpListToolsTimeout(server="local")]),
    content={
      "name": "local",
      "transport": "stdio",
      "target": "npx",
      "state": "failed",
      "error": "timed out listing its tools",
    },
  )
  json_inspect(server_report(stdio, [], [McpNoTools(server="local")]), content={
    "name": "local",
    "transport": "stdio",
    "target": "npx",
    "state": "no_tools",
  })
  json_inspect(
    server_report(stdio, [], [McpServerSkippedOverCap(server="local")]),
    content={
      "name": "local",
      "transport": "stdio",
      "target": "npx",
      "state": "skipped",
    },
  )
}
