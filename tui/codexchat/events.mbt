///|
/// Apply one `codex.notification` envelope. Snapshots, terminal items, and
/// deltas update the same item identities, so a late completion replaces its
/// transient text and cannot produce a second assistant answer.
pub fn State::apply(self : State, notification : Json) -> Thread? {
  guard text(notification, "method") is Some(method_) &&
    field(notification, "params") is Some(params) else {
    return None
  }
  if method_ == "serverRequest/resolved" {
    if generation(notification) is Some(next) &&
      next > self.request_generation &&
      field(params, "requestId") is Some(request_id) {
      self.requests = self.requests.filter(request => {
        request.request_id != request_id
      })
      self.request_generation = next
    }
    return None
  }
  if method_ == "thread/started" &&
    field(params, "thread").bind(decode_thread) is Some(thread) {
    self.revisions[thread.id] = self.revisions.get(thread.id).unwrap_or(0) + 1
    return Some(self.install(thread, preserve=true))
  }
  guard text(params, "threadId") is Some(id) else { return None }
  let previous = self.threads.get(id).unwrap_or_else(() => empty_thread(id))
  let next = match method_ {
    "turn/started" | "turn/completed" => {
      guard field(params, "turn") is Some(turn) else { return None }
      // A predecessor's delayed terminal cannot close a successor turn.
      if method_ == "turn/completed" &&
        previous.turn_id is Some(active) &&
        text(turn, "id") is Some(completed) &&
        active != completed {
        let reconciled = with_turn(previous, turn, complete=true)
        { ..reconciled, turn_id: previous.turn_id, status: previous.status, }
      } else {
        with_turn(previous, turn, complete=method_ == "turn/completed")
      }
    }
    "item/started" | "item/completed" => {
      guard text(params, "turnId") is Some(turn_id) &&
        field(params, "item").bind(value => {
          decode_item(value, turn_id, complete=method_ == "item/completed")
        })
        is Some(item) else {
        return None
      }
      { ..previous, messages: replace_message(previous.messages, item), }
    }
    "item/agentMessage/delta"
    | "item/plan/delta"
    | "item/reasoning/summaryTextDelta"
    | "item/reasoning/textDelta"
    | "item/commandExecution/outputDelta" => {
      guard text(params, "turnId") is Some(turn_id) &&
        text(params, "itemId") is Some(item_id) &&
        text(params, "delta") is Some(delta) else {
        return None
      }
      let item_key = turn_id + "/" + item_id
      let role = match method_ {
        "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" =>
          "reasoning"
        "item/commandExecution/outputDelta" => "tool"
        "item/plan/delta" => "plan"
        _ => "assistant"
      }
      let current = previous.messages
        .iter()
        .find_first(item => item.id == item_key)
      if current is Some({ complete: true, .. }) {
        return Some(previous)
      }
      let content = current.map(item => item.text).unwrap_or("") + delta
      {
        ..previous,
        messages: replace_message(previous.messages, {
          id: item_key,
          role,
          text: content,
          complete: false,
          tool: if role == "tool" {
            Some(
              current
              .bind(item => item.tool)
              .unwrap_or_else(() => @toolcall.Call(item_key, "shell"))
              .finish(content, status=Pending),
            )
          } else {
            None
          },
        }),
      }
    }
    "thread/name/updated" => {
      guard text(params, "name") is Some(title) else { return None }
      { ..previous, title, }
    }
    "thread/status/changed" => {
      guard field(params, "status").bind(value => text(value, "type"))
        is Some(status) else {
        return None
      }
      {
        ..previous,
        status: if status == "active" {
          "inProgress"
        } else {
          status
        },
        turn_id: if status is ("idle" | "notLoaded" | "systemError") {
          None
        } else {
          previous.turn_id
        },
      }
    }
    "thread/archived" =>
      { ..previous, status: "archived", archived: true, turn_id: None, }
    "thread/unarchived" => { ..previous, status: "idle", archived: false, }
    "error" | "warning" => {
      let message = if text(params, "message") is Some(message) {
        message
      } else {
        field(params, "error")
        .bind(value => text(value, "message"))
        .unwrap_or(method_)
      }
      {
        ..previous,
        messages: [
          ..previous.messages,
          {
            id: "notice/\{self.revisions.get(id).unwrap_or(0)}",
            role: "error",
            tool: None,
            text: message,
            complete: true,
          },
        ],
      }
    }
    _ => return None
  }
  self.revisions[id] = self.revisions.get(id).unwrap_or(0) + 1
  Some(self.put(next))
}

///|
fn decode_request(value : Json, generation : Int32) -> PendingRequest? {
  guard text(value, "response_token") is Some(response_token) &&
    field(value, "request_id") is Some(request_id) &&
    text(value, "method") is Some(method_) &&
    field(value, "params") is Some(params) else {
    return None
  }
  Some({
    response_token,
    request_id,
    method_,
    thread_id: text(params, "threadId"),
    params,
    generation,
  })
}

///|
/// Live requests and snapshots share one generation frontier. A delayed
/// snapshot cannot resurrect a question already resolved by another client.
pub fn State::apply_request(self : State, value : Json) -> Bool {
  guard generation(value) is Some(next) &&
    next > self.request_generation &&
    decode_request(value, next) is Some(request) else {
    return false
  }
  self.requests = self.requests.filter(previous => {
    previous.request_id != request.request_id
  })
  self.requests.push(request)
  self.request_generation = next
  true
}

///|
pub fn State::apply_request_snapshot(
  self : State,
  snapshot : @protocol.CodexServerRequestsReply,
) -> Unit {
  if snapshot.generation > self.request_generation {
    self.requests = snapshot.data.filter_map(value => {
      decode_request(value, snapshot.generation)
    })
    self.request_generation = snapshot.generation
  }
}

///|
/// Ordinary approval cards have direct yes/no actions. User-input questions
/// and elicitation content use the explicit JSON response operation instead.
pub fn PendingRequest::approval_result(
  self : PendingRequest,
  allow : Bool,
) -> Json? {
  match self.method_ {
    "item/commandExecution/requestApproval"
    | "item/fileChange/requestApproval" =>
      Some({ "decision": if allow { "accept" } else { "decline" } })
    "item/permissions/requestApproval" =>
      if !allow {
        Some({ "permissions": {}, "scope": "turn" })
      } else if field(self.params, "permissions") is Some(permissions) {
        Some({ "permissions": permissions, "scope": "turn" })
      } else {
        None
      }
    "mcpServer/elicitation/request" if !allow =>
      Some({ "action": "decline", "content": Json::null() })
    _ => None
  }
}

///|
/// Submit all answers in a request using the app-server's per-question format.
pub fn PendingRequest::answer_result(
  self : PendingRequest,
  answers : Map[String, String],
) -> Json raise CodexError {
  guard self.method_ == "item/tool/requestUserInput" &&
    field(self.params, "questions") is Some(Array(questions)) else {
    raise CodexError("This request does not contain user-input questions")
  }
  let result : Map[String, Json] = Map([])
  for question in questions {
    guard text(question, "id") is Some(id) &&
      answers.get(id) is Some(answer) &&
      !answer.trim().is_empty() else {
      raise CodexError("Every question needs an answer before submitting")
    }
    result[id] = { "answers": [Json(answer)] }
  }
  { "answers": Json(result) }
}
