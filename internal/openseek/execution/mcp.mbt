///|
/// The client version openseek advertises to MCP servers in the handshake.
pub const McpClientVersion : String = "0.2.2"

///|
/// What this engine holds of MCP: whether it was configured, and for each
/// configured server what connecting came to. Built once at startup and kept
/// for the engine's life, because the connections are — it is what an
/// `mcp_snapshot` reads back.
enum McpRegistry {
  NotConfigured
  /// The configuration could not be read or decoded, so there are no servers.
  Rejected(path~ : String, reason~ : String)
  Loaded(path~ : String, entries~ : Array[@mcptools.ServerEntry])
}

///|
/// Connect the configured MCP servers. Nothing here fails the engine: a
/// configuration that cannot be used and a server that cannot be reached are
/// recorded in the registry and reported as the events they always were. The
/// connections' reader/writer tasks run on `scope`'s group.
async fn[X] connect_mcp(
  scope : @agent_runtime.AgentTaskScope[X],
  workspace_root~ : String,
  config_path? : String,
) -> McpRegistry {
  guard config_path is Some(path) else { return NotConfigured }
  let text = @fs.read_file(path).text() catch {
    error => {
      @emit.emit(McpConfigUnreadable(path~, error="\{error}"))
      return Rejected(path~, reason="\{error}")
    }
  }
  let servers = @mcpconfig.decode(@json.parse(text)) catch {
    error => {
      @emit.emit(McpConfigInvalid(path~, error="\{error}"))
      return Rejected(path~, reason="\{error}")
    }
  }
  let entries = @mcptools.connect(
    scope,
    servers,
    client_name="openseek",
    client_version=McpClientVersion,
    workspace_root~,
  )
  let registry = Loaded(path~, entries~)
  let tools = registry.tools()
  @emit.emit(
    McpToolsRegistered(
      servers=servers.length(),
      tools=tools.length(),
      names=[ for tool in tools => tool.name ],
    ),
  )
  registry
}

///|
/// The agent tools the connected servers contributed, in config order.
fn McpRegistry::tools(
  self : McpRegistry,
) -> Array[@agent_tool.AgentToolDefinition] {
  guard self is Loaded(entries~, ..) else { return [] }
  entries.map(entry => entry.tools).flatten()
}

///|
/// The registry as the `mcp_snapshot` event reports it. A server's state is
/// read now, not remembered: one that connected at startup and has since lost
/// its connection is `Lost`, with the tools that are still registered.
pub fn McpRegistry::status(self : McpRegistry) -> @protocol.McpStatus {
  match self {
    NotConfigured => NotConfigured
    Rejected(path~, reason~) => ConfigRejected(path~, reason~)
    Loaded(path~, entries~) =>
      Configured(
        path~,
        servers=entries.map(entry => {
          let tools : Array[@protocol.McpTool] = entry.tools.map(tool => {
            name: tool.name,
            description: tool.description,
          })
          let state : @protocol.McpServerState = match entry.connection {
            Live(client) =>
              if client.is_closed() {
                Lost(tools)
              } else {
                Connected(tools)
              }
            NoTools => NoTools
            Failed(reason) => Failed(reason)
            Skipped => Skipped
          }
          {
            name: entry.server.name(),
            transport: match entry.server {
              Stdio(..) => Stdio
              Http(..) => Http
            },
            target: entry.server.target(),
            state,
          }
        }),
      )
  }
}
