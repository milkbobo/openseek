///|
/// The client version openseek advertises to MCP servers in the handshake.
pub const McpClientVersion : String = "0.2.2"

///|
/// What reading the configuration file came to. Kept beside what was made of
/// it, so the next read can tell whether there is anything new to act on. A
/// file that is not there and one that cannot be read are different answers:
/// the first is the ordinary state of a path nobody has written yet.
priv enum McpSource {
  Missing
  Unreadable(String)
  Text(String)
} derive(Eq)

///|
/// What the engine made of its configuration file as last read.
priv enum McpLoad {
  /// There is no file at the path, so there are no servers. Nothing is wrong:
  /// the file is loaded if it appears.
  Absent
  /// The file could not be read or decoded, so there are no servers.
  Rejected(String)
  /// The file's servers, in its order, with what connecting each came to.
  Loaded(Array[@mcptools.ServerEntry])
}

///|
priv struct McpFile {
  path : String
  source : McpSource
  load : McpLoad
}

///|
/// What this engine holds of MCP: the configuration file it was pointed at,
/// if any, and for each server in it what connecting came to. It is kept for
/// the engine's life because the connections are, and it is what an
/// `mcp_status` event reports. `reload` brings it up to date with the file.
struct McpRegistry {
  // `None` when the engine was started without an MCP configuration. Replaced
  // as a whole, so a reader never sees a half-made registry.
  mut file : McpFile?
  // Run when a live connection closes; installed on each as it is made.
  mut on_closed : () -> Unit
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
  let registry : McpRegistry = { file: None, on_closed: () => (), }
  if config_path is Some(path) {
    registry.load(scope, workspace_root~, path, read_source(path), previous=[])
  }
  registry
}

///|
async fn read_source(path : String) -> McpSource {
  let text = @fs.read_file(path).text() catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => return Missing
    error if @async.is_being_cancelled() => raise error
    error => return Unreadable("\{error}")
  }
  Text(text)
}

///|
/// Make the registry what `source` describes. Connections in `previous` that
/// the new configuration keeps unchanged carry over; the rest are closed.
/// The registry is only replaced at the end, so a cancelled call leaves the
/// earlier one in place, still naming the earlier source.
///
/// The close handler is off for the duration: the connections this lets go
/// are not news, and until the registry is replaced a report would describe
/// them as lost. The caller reports once this returns or is cancelled.
async fn[X] McpRegistry::load(
  self : McpRegistry,
  scope : @agent_runtime.AgentTaskScope[X],
  workspace_root~ : String,
  path : String,
  source : McpSource,
  previous~ : Array[@mcptools.ServerEntry],
) -> Unit {
  for entry in previous {
    if entry.connection is Live(client) {
      client.set_close_handler(() => ())
    }
  }
  defer self.watch_connections()
  // No servers to keep: every earlier connection goes.
  fn release() {
    for entry in previous {
      if entry.connection is Live(client) {
        client.close()
      }
    }
  }

  let load : McpLoad = match source {
    Missing => {
      release()
      Absent
    }
    Unreadable(error) => {
      release()
      @emit.emit(McpConfigUnreadable(path~, error~))
      Rejected(error)
    }
    Text(text) =>
      try @mcpconfig.decode(@json.parse(text)) catch {
        error => {
          release()
          @emit.emit(McpConfigInvalid(path~, error="\{error}"))
          Rejected("\{error}")
        }
      } noraise {
        servers => {
          let entries = @mcptools.connect(
            scope,
            servers,
            client_name="openseek",
            client_version=McpClientVersion,
            workspace_root~,
            previous~,
          )
          let names : Array[String] = []
          for entry in entries {
            for tool in entry.tools {
              names.push(tool.name)
            }
          }
          @emit.emit(
            McpToolsRegistered(
              servers=servers.length(),
              tools=names.length(),
              names~,
            ),
          )
          Loaded(entries)
        }
      }
  }
  self.file = Some({ path, source, load, })
}

///|
fn McpRegistry::entries(self : McpRegistry) -> Array[@mcptools.ServerEntry] {
  match self.file {
    Some({ load: Loaded(entries), .. }) => entries
    _ => []
  }
}

///|
fn McpRegistry::watch_connections(self : McpRegistry) -> Unit {
  for entry in self.entries() {
    if entry.connection is Live(client) {
      client.set_close_handler(self.on_closed)
    }
  }
}

///|
/// The agent tools the connected servers contributed, in config order.
fn McpRegistry::tools(
  self : McpRegistry,
) -> Array[@agent_tool.AgentToolDefinition] {
  self.entries().map(entry => entry.tools).flatten()
}

///|
/// Run `handler` each time a connected server's connection closes on its own
/// — the server exited, or the transport failed. A connection `reload` lets
/// go does not run it. The handler must not block. A connection that closed
/// before this call does not run it either, so a caller reads `status` after
/// installing and reports from there.
pub fn McpRegistry::on_connection_closed(
  self : McpRegistry,
  handler : () -> Unit,
) -> Unit {
  self.on_closed = handler
  self.watch_connections()
}

///|
/// The MCP tools to take out of a tool registry and the ones to put in, after
/// a reload that found the configuration changed.
pub struct McpToolsChange {
  removed : Array[String]
  added : Array[@agent_tool.AgentToolDefinition]
}

///|
/// Read the configuration file again and, if it is not what was last read,
/// bring the registry in line with it: servers the file still defines the
/// same way keep their connections, changed and new ones are connected, and
/// the rest are closed. Returns the resulting change to the MCP tools, or
/// `None` when the file is as it was — including a server that has failed or
/// been lost since, which is not retried until the file changes.
///
/// For the gap between turns: a tool call in flight on a connection this
/// closes would fail. An engine started without a configuration has no file
/// to read. Cancelling it leaves the registry on the earlier read, possibly
/// with connections already let go, and the next call starts over. Either
/// way the status may have changed without the close handler running, so the
/// caller reads it again afterwards.
pub async fn[X] McpRegistry::reload(
  self : McpRegistry,
  scope : @agent_runtime.AgentTaskScope[X],
  workspace_root~ : String,
) -> McpToolsChange? {
  guard self.file is Some(file) else { return None }
  let source = read_source(file.path)
  guard source != file.source else { return None }
  let removed = self.tools().map(tool => tool.name)
  self.load(scope, workspace_root~, file.path, source, previous=self.entries())
  Some({ removed, added: self.tools(), })
}

///|
/// The registry as the `mcp_status` event reports it. A server's state is
/// read now, not remembered: one that connected and has since lost its
/// connection is `Lost`, with the tools that are still registered.
pub fn McpRegistry::status(self : McpRegistry) -> @protocol.McpStatus {
  guard self.file is Some({ path, load, .. }) else { return NotConfigured }
  match load {
    Absent => ConfigAbsent(path~)
    Rejected(reason) => ConfigRejected(path~, reason~)
    Loaded(entries) =>
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
