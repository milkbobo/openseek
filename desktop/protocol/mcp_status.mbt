// What the MCP panel shows: the servers of the user's MCP configuration and
// what connecting to each one yields. The per-server shape is the engine's —
// `openseek mcp --format json` prints it and the host forwards it unchanged —
// so one codec reads both the engine's report and the host's reply.

///|
/// One tool a connected MCP server registered, under its namespaced name
/// (`mcp__<server>__<tool>`).
pub(all) struct McpTool {
  name : String
  description : String
} derive(Eq, Debug)

///|
pub impl FromJson for McpTool with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "MCP tool")
  {
    name: object.required_string("name"),
    description: object.required_string("description"),
  }
}

///|
pub impl ToJson for McpTool with fn to_json(self) {
  { "name": self.name, "description": self.description }
}

///|
pub extend McpTool with Eq::{equal, not_equal}

///|
pub extend McpTool with Debug::{to_repr}

///|
pub extend McpTool with FromJson::{from_json}

///|
pub extend McpTool with ToJson::{to_json}

///|
/// How a configured server is reached: a subprocess speaking over stdio, or a
/// Streamable HTTP endpoint.
pub(all) enum McpTransport {
  Stdio
  Http
} derive(Eq, Debug)

///|
pub extend McpTransport with Eq::{equal, not_equal}

///|
pub extend McpTransport with Debug::{to_repr}

///|
/// What connecting to one configured server yielded.
pub(all) enum McpServerState {
  /// Connected, with the tools it registered (never empty).
  Connected(Array[McpTool])
  /// Connected, and it offers no tools.
  NoTools
  /// It could not be started, reached, or asked for its tools.
  Failed(String)
  /// Never tried: earlier servers had already used up the tool budget.
  Skipped
} derive(Eq, Debug)

///|
pub extend McpServerState with Eq::{equal, not_equal}

///|
pub extend McpServerState with Debug::{to_repr}

///|
/// One server of the configuration. `target` is its command (stdio) or its
/// URL without credentials (http); arguments, environment, and headers are
/// never reported because they are where tokens live.
pub(all) struct McpServerStatus {
  name : String
  transport : McpTransport
  target : String
  state : McpServerState
} derive(Eq, Debug)

///|
pub impl FromJson for McpServerStatus with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "MCP server status")
  let transport = match object.required_string("transport") {
    "stdio" => Stdio
    "http" => Http
    _ =>
      raise JsonDecodeError(
        (path.add_key("transport"), "expected MCP transport"),
      )
  }
  let state = match object.required_string("state") {
    "connected" => {
      let tools : Array[McpTool] = object.required_array_of("tools")
      guard !tools.is_empty() else {
        raise JsonDecodeError(
          (path.add_key("tools"), "a connected MCP server lists its tools"),
        )
      }
      Connected(tools)
    }
    "no_tools" => NoTools
    "failed" => Failed(object.required_string("error"))
    "skipped" => Skipped
    _ =>
      raise JsonDecodeError(
        (path.add_key("state"), "expected MCP server state"),
      )
  }
  {
    name: object.required_string("name"),
    transport,
    target: object.required_string("target"),
    state,
  }
}

///|
pub impl ToJson for McpServerStatus with fn to_json(self) {
  let fields : Map[String, Json] = {
    "name": self.name.to_json(),
    "transport": match self.transport {
      Stdio => "stdio"
      Http => "http"
    },
    "target": self.target.to_json(),
  }
  match self.state {
    Connected(tools) => {
      fields["state"] = "connected"
      fields["tools"] = tools.to_json()
    }
    NoTools => fields["state"] = "no_tools"
    Failed(error) => {
      fields["state"] = "failed"
      fields["error"] = error.to_json()
    }
    Skipped => fields["state"] = "skipped"
  }
  Json::object(fields)
}

///|
pub extend McpServerStatus with Eq::{equal, not_equal}

///|
pub extend McpServerStatus with Debug::{to_repr}

///|
pub extend McpServerStatus with FromJson::{from_json}

///|
pub extend McpServerStatus with ToJson::{to_json}

///|
/// The engine's `openseek mcp --format json` report: `{"servers": […]}` in
/// configuration order.
priv struct McpReport(Array[McpServerStatus])

///|
impl FromJson for McpReport with fn from_json(json, path) {
  McpReport(
    JsonObject::decode(json, path, "MCP report").required_array_of("servers"),
  )
}

///|
/// Decode the engine's `openseek mcp --format json` report into its servers.
pub fn McpServerStatus::from_report(
  report : Json,
) -> Array[McpServerStatus] raise @json.JsonDecodeError {
  let McpReport(servers) = @json.from_json(report)
  servers
}

///|
/// The reply of `mcp.status`. `path` is where the host looks for the
/// configuration, on the machine the host runs on.
pub(all) enum McpStatusReply {
  /// There is no configuration file: nothing is configured.
  NoConfig(path~ : String)
  /// The file exists and the engine cannot use it — unreadable, not JSON, or
  /// not the `mcpServers` shape.
  ConfigRejected(path~ : String, reason~ : String)
  /// The configuration loaded; these are its servers, in file order.
  Configured(path~ : String, servers~ : Array[McpServerStatus])
} derive(Eq, Debug)

///|
pub impl FromJson for McpStatusReply with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "MCP status reply")
  let config_path = object.required_string("path")
  match object.required_string("config") {
    "absent" => NoConfig(path=config_path)
    "rejected" =>
      ConfigRejected(path=config_path, reason=object.required_string("reason"))
    "loaded" =>
      Configured(path=config_path, servers=object.required_array_of("servers"))
    _ =>
      raise JsonDecodeError(
        (path.add_key("config"), "expected MCP configuration state"),
      )
  }
}

///|
pub impl ToJson for McpStatusReply with fn to_json(self) {
  match self {
    NoConfig(path~) => { "config": "absent", "path": path }
    ConfigRejected(path~, reason~) =>
      { "config": "rejected", "path": path, "reason": reason }
    Configured(path~, servers~) =>
      { "config": "loaded", "path": path, "servers": servers }
  }
}

///|
pub extend McpStatusReply with Eq::{equal, not_equal}

///|
pub extend McpStatusReply with Debug::{to_repr}

///|
pub extend McpStatusReply with FromJson::{from_json}

///|
pub extend McpStatusReply with ToJson::{to_json}
