///|
/// A semantic app-server item. Item identity prevents snapshots and streamed
/// deltas from appending duplicate user or assistant messages.
pub struct Message {
  id : String
  role : String
  text : String
  complete : Bool
}

///|
pub struct Thread {
  id : String
  title : String
  cwd : String?
  project_root : String?
  status : String
  turn_id : String?
  messages : Array[Message]
}

///|
pub struct PendingRequest {
  response_token : String
  request_id : Json
  method_ : String
  thread_id : String?
  params : Json
  generation : Int32
}

///|
pub(all) suberror CodexError {
  CodexError(String)
} derive(Debug)

///|
pub extend CodexError with Debug::{to_repr}

///|
struct State {
  threads : Map[String, Thread]
  order : Array[String]
  revisions : Map[String, Int32]
  mut requests : Array[PendingRequest]
  mut request_generation : Int32
}

///|
pub fn State::State() -> State {
  {
    threads: {},
    order: [],
    revisions: {},
    requests: [],
    request_generation: -1,
  }
}

///|
pub fn State::thread(self : State, id : String) -> Thread? {
  self.threads.get(id)
}

///|
pub fn State::threads(self : State) -> Array[Thread] {
  self.order.filter_map(id => self.threads.get(id))
}

///|
pub fn State::requests(self : State) -> Array[PendingRequest] {
  self.requests.copy()
}

///|
fn empty_thread(id : String) -> Thread {
  {
    id,
    title: id,
    cwd: None,
    project_root: None,
    status: "idle",
    turn_id: None,
    messages: [],
  }
}

///|
fn State::put(self : State, thread : Thread) -> Thread {
  if !self.threads.contains(thread.id) {
    self.order.push(thread.id)
  }
  self.threads[thread.id] = thread
  thread
}

///|
fn text(value : Json, key : String) -> String? {
  if value is Object(fields) && fields.get(key) is Some(String(value)) {
    Some(value)
  } else {
    None
  }
}

///|
fn field(value : Json, key : String) -> Json? {
  if value is Object(fields) {
    fields.get(key)
  } else {
    None
  }
}

///|
fn generation(value : Json) -> Int32? {
  if field(value, "generation") is Some(Number(number, ..)) &&
    number >= 0 &&
    number <= 2147483647.0 &&
    number.to_int().to_double() == number {
    Some(number.to_int())
  } else {
    None
  }
}

///|
fn parts(value : Json) -> String {
  match value {
    String(value) => value
    Array(values) =>
      values.map(parts).filter(value => !value.is_empty()).join("\n")
    Object(_) => text(value, "text").unwrap_or("")
    _ => ""
  }
}

///|
fn decode_item(value : Json, turn : String, complete~ : Bool) -> Message? {
  guard text(value, "id") is Some(id) && text(value, "type") is Some(kind) else {
    return None
  }
  let role = match kind {
    "userMessage" => "user"
    "agentMessage" => "assistant"
    "reasoning" => "reasoning"
    "plan" => "plan"
    _ => "tool"
  }
  let body = match kind {
    "userMessage" => field(value, "content").map(parts).unwrap_or("")
    "agentMessage" | "plan" => text(value, "text").unwrap_or("")
    "reasoning" => {
      let summary = field(value, "summary").map(parts).unwrap_or("")
      if summary.is_empty() {
        field(value, "content").map(parts).unwrap_or("")
      } else {
        summary
      }
    }
    "commandExecution" => {
      let command = text(value, "command").unwrap_or("Shell command")
      if text(value, "aggregatedOutput") is Some(output) && !output.is_empty() {
        command + "\n" + output
      } else if complete {
        command
      } else {
        command + "\n"
      }
    }
    "fileChange" =>
      field(value, "changes")
      .map(value => value.stringify(indent=2))
      .unwrap_or("Files changed")
    "webSearch" => "Search: " + text(value, "query").unwrap_or("")
    "imageView" => "Image: " + text(value, "path").unwrap_or("")
    "contextCompaction" => "Context compacted"
    "enteredReviewMode" | "exitedReviewMode" =>
      text(value, "review").unwrap_or(kind)
    _ => value.stringify(indent=2)
  }
  Some({
    id: turn + "/" + id,
    role,
    text: body,
    complete: complete || role == "user",
  })
}

///|
fn replace_message(messages : Array[Message], next : Message) -> Array[Message] {
  let mut replaced = false
  let result = messages.map(previous => {
    if previous.id == next.id {
      replaced = true
      if !next.complete && (previous.complete || next.text.is_empty()) {
        previous
      } else {
        next
      }
    } else {
      previous
    }
  })
  if !replaced {
    result.push(next)
  }
  result
}

///|
fn with_turn(thread : Thread, turn : Json, complete~ : Bool) -> Thread {
  guard text(turn, "id") is Some(turn_id) else { return thread }
  let status = text(turn, "status").unwrap_or(
    if complete {
      "completed"
    } else {
      "inProgress"
    },
  )
  let active = !complete && status is ("inProgress" | "running")
  let mut messages = if !active {
    thread.messages.map(message => {
      if message.id.has_prefix(turn_id + "/") {
        { ..message, complete: true, }
      } else {
        message
      }
    })
  } else {
    thread.messages
  }
  if field(turn, "items") is Some(Array(items)) {
    for item in items {
      if decode_item(item, turn_id, complete=!active) is Some(item) {
        messages = replace_message(messages, item)
      }
    }
  }
  if field(turn, "error").bind(value => text(value, "message")) is Some(message) {
    messages = replace_message(messages, {
      id: turn_id + "/error",
      role: "error",
      text: message,
      complete: true,
    })
  }
  {
    ..thread,
    messages,
    status,
    turn_id: if active {
      Some(turn_id)
    } else {
      None
    },
  }
}

///|
/// Decode the independently versioned nested app-server thread. Unknown item
/// kinds retain their data as text instead of disappearing from the transcript.
pub fn decode_thread(value : Json) -> Thread? {
  guard text(value, "id") is Some(id) && !id.is_empty() else { return None }
  let cwd = if field(value, "openseekWorktree").bind(value => {
      text(value, "path")
    })
    is Some(path) {
    Some(path)
  } else {
    text(value, "cwd")
  }
  let title = text(value, "name").unwrap_or_else(() => {
    text(value, "preview").unwrap_or(id)
  })
  let status = field(value, "status")
    .bind(value => text(value, "type"))
    .unwrap_or("idle")
  let mut thread = {
    ..empty_thread(id),
    title,
    cwd,
    project_root: text(value, "projectRoot"),
    status,
  }
  if field(value, "turns") is Some(Array(turns)) {
    for turn in turns {
      thread = with_turn(thread, turn, complete=false)
    }
  }
  Some(thread)
}

///|
fn State::install(self : State, incoming : Thread, preserve~ : Bool) -> Thread {
  let incoming = if self.threads.get(incoming.id) is Some(previous) && preserve {
    let mut messages = incoming.messages
    for live in previous.messages {
      if !messages.any(message => message.id == live.id) {
        messages.push(live)
      } else if !live.complete {
        messages = messages.map(message => {
          if message.id == live.id &&
            !message.complete &&
            live.text.length() > message.text.length() {
            live
          } else {
            message
          }
        })
      }
    }
    {
      ..incoming,
      messages,
      status: previous.status,
      turn_id: previous.turn_id,
    }
  } else {
    incoming
  }
  self.put(incoming)
}
