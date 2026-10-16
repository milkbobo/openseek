///|
/// Save a text resource using the same absolute/root-relative addresses as
/// `ReadFilePayload`. `session` identifies the calling chat, not the path scope.
/// `expected_content=None` creates a missing file; `Some(text)` replaces only
/// that exact previously loaded version and refuses a missing or changed file.
pub(all) struct WriteFilePayload {
  session : String
  root : String?
  path : String
  content : String
  expected_content : String?
} derive(Debug, Eq)

///|
/// The absolute resource path of the saved file.
pub(all) struct WriteFileReply {
  path : String
} derive(Debug, Eq)

///|
pub impl FromJson for WriteFilePayload with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "write file payload")
  {
    session: object.required_string("session"),
    root: object.optional_string("root"),
    path: object.required_string("path"),
    content: object.required_string("content"),
    expected_content: object.optional_string("expected_content"),
  }
}

///|
pub impl ToJson for WriteFilePayload with fn to_json(self) {
  {
    "session": Json(self.session),
    "root": if self.root is Some(root) {
      Json(root)
    } else {
      Json::null()
    },
    "path": Json(self.path),
    "content": Json(self.content),
    "expected_content": if self.expected_content is Some(content) {
      Json(content)
    } else {
      Json::null()
    },
  }
}

///|
pub impl FromJson for WriteFileReply with fn from_json(json, path) {
  let object = JsonObject::decode(json, path, "write file reply")
  { path: object.required_string("path"), }
}

///|
pub impl ToJson for WriteFileReply with fn to_json(self) {
  { "path": Json(self.path) }
}

///|
pub extend WriteFilePayload with Debug::{to_repr}

///|
pub extend WriteFilePayload with Eq::{equal, not_equal}

///|
pub extend WriteFilePayload with FromJson::{from_json}

///|
pub extend WriteFilePayload with ToJson::{to_json}

///|
pub extend WriteFileReply with Debug::{to_repr}

///|
pub extend WriteFileReply with Eq::{equal, not_equal}

///|
pub extend WriteFileReply with FromJson::{from_json}

///|
pub extend WriteFileReply with ToJson::{to_json}
