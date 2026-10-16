///|
/// Preserve actionable diagnostics across Proton's rejected-promise boundary.
pub(all) enum SshOperation[T] {
  SshCompleted(T)
  SshFailed(String)
}

///|
pub impl[T : ToJson] ToJson for SshOperation[T] with fn to_json(self) {
  match self {
    SshCompleted(value) => { "status": "completed", "value": value }
    SshFailed(message) => { "status": "failed", "message": message }
  }
}

///|
pub impl[T : FromJson] FromJson for SshOperation[T] with fn from_json(
  json,
  path,
) {
  let object = JsonObject::decode(json, path, "SSH operation")
  match object.required_string("status") {
    "completed" =>
      SshCompleted(
        @json.from_json(
          object.required_json("value"),
          path=path.add_key("value"),
        ),
      )
    "failed" => SshFailed(object.required_string("message"))
    _ => raise JsonDecodeError((path, "invalid SSH operation status"))
  }
}

///|
pub extend SshOperation with ToJson::{to_json}

///|
pub extend SshOperation with FromJson::{from_json}
