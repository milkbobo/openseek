// `mcp.status`: what a conversation's engine holds of its MCP servers. The
// state itself is the engine's (`@wire.McpStatus`, the payload of its
// `mcp_snapshot` event); the host adds only what the engine cannot know —
// that no engine is running, and where this host looks for the configuration.

///|
/// The conversation whose engine is asked.
pub(all) struct McpStatusPayload {
  session : String
} derive(Eq, Debug)

///|
pub impl FromJson for McpStatusPayload with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "MCP status request")
  { session: object.required_string("session"), }
}

///|
pub impl ToJson for McpStatusPayload with fn to_json(self) {
  { "session": self.session }
}

///|
pub extend McpStatusPayload with Eq::{equal, not_equal}

///|
pub extend McpStatusPayload with Debug::{to_repr}

///|
pub extend McpStatusPayload with FromJson::{from_json}

///|
pub extend McpStatusPayload with ToJson::{to_json}

///|
/// Whether there was an engine to ask, and what it answered.
pub(all) enum McpEngineStatus {
  /// The conversation has no engine running — it has not been sent a message
  /// since the host started, or its engine has exited. Servers connect when
  /// the next message starts one.
  NotRunning
  /// The running engine's own account of its servers.
  Running(@wire.McpStatus)
} derive(Eq, Debug)

///|
pub extend McpEngineStatus with Eq::{equal, not_equal}

///|
pub extend McpEngineStatus with Debug::{to_repr}

///|
/// The reply of `mcp.status`. `config_path` is where this host looks for the
/// MCP configuration, on the machine the host runs on — what a conversation's
/// next engine will be pointed at, whatever the current one was started with.
pub(all) struct McpStatusReply {
  config_path : String
  engine : McpEngineStatus
} derive(Eq, Debug)

///|
pub impl FromJson for McpStatusReply with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "MCP status reply")
  let engine = match object.required_string("engine") {
    "stopped" => NotRunning
    "running" =>
      Running(
        @json.from_json(
          object.required_json("status"),
          path=path.add_key("status"),
        ),
      )
    _ =>
      raise JsonDecodeError((path.add_key("engine"), "expected engine state"))
  }
  { config_path: object.required_string("config_path"), engine, }
}

///|
pub impl ToJson for McpStatusReply with fn to_json(self) {
  match self.engine {
    NotRunning => { "config_path": self.config_path, "engine": "stopped" }
    Running(status) =>
      {
        "config_path": self.config_path,
        "engine": "running",
        "status": Json(status),
      }
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
