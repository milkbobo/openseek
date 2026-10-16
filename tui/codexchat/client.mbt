///|
fn[Reply] success(
  reply : @protocol.CodexCommandReply[Reply],
) -> Reply raise CodexError {
  match reply {
    @protocol.CodexCommandSuccess(value) => value
    @protocol.CodexCommandError(message) => raise CodexError(message)
  }
}

///|
fn required_thread(
  reply : @protocol.CodexThreadReply,
) -> Thread raise CodexError {
  decode_thread(reply.thread).unwrap_or_error(
    CodexError("Codex returned a malformed thread"),
  )
}

///|
pub async fn State::list(
  self : State,
  client : @client.Client,
  archived~ : Bool = false,
  only? : Set[String],
) -> Array[Thread] {
  let result : Array[Thread] = []
  let mut cursor : String? = None
  for ;; {
    let before = self.revisions.copy()
    let reply = success(
      client.call(@commands.codex_thread_list, { limit: 100, archived, cursor, }),
    )
    for value in reply.data {
      if decode_thread(value) is Some(thread) {
        if only is Some(ids) && !ids.contains(thread.id) {
          continue
        }
        let thread = self.install(thread, preserve=true)
        result.push(
          self.put({
            ..thread,
            archived: if self.revisions.get(thread.id) == before.get(thread.id) {
              archived
            } else {
              thread.archived
            },
          }),
        )
      }
    }
    guard reply.next_cursor is Some(next) else { break }
    cursor = Some(next)
  }
  result
}

///|
pub async fn State::start(
  self : State,
  client : @client.Client,
  cwd? : String,
  model? : String,
  permission_mode~ : @protocol.CodexPermissionMode = RequestApproval,
) -> Thread {
  let reply = success(
    client.call(@commands.codex_thread_start, {
      cwd,
      model,
      draft_id: None,
      permission_mode,
    }),
  )
  self.install(required_thread(reply), preserve=true)
}

///|
pub async fn State::read(
  self : State,
  client : @client.Client,
  id : String,
) -> Thread {
  let before = self.revisions.get(id).unwrap_or(0)
  let reply = success(
    client.call(@commands.codex_thread_read, {
      thread_id: id,
      include_turns: Some(true),
    }),
  )
  self.install(
    required_thread(reply),
    preserve=self.revisions.get(id).unwrap_or(0) != before,
  )
}

///|
/// A normal submit starts a new turn when idle and steers the exact active
/// turn while running, matching the shared desktop composer's send behavior.
pub async fn State::send(
  self : State,
  client : @client.Client,
  id : String,
  prompt : String,
  model? : String,
  effort? : String,
  images~ : Array[String] = [],
  permission_mode~ : @protocol.CodexPermissionMode = RequestApproval,
) -> Thread {
  guard !prompt.trim().is_empty() || !images.is_empty() else {
    raise CodexError("A prompt cannot be empty")
  }
  let thread = self.thread(id).unwrap_or_else(() => empty_thread(id))
  if thread.turn_id is Some(_) {
    return self.steer(client, id, prompt, images~)
  }
  // Resuming restores app-server ownership after reconnect or loading history.
  let resumed = success(
    client.call(@commands.codex_thread_resume, {
      thread_id: id,
      permission_mode,
    }),
  )
  let thread = self.install(required_thread(resumed), preserve=true)
  let before = self.revisions.get(id).unwrap_or(0)
  let reply = success(
    client.call(@commands.codex_turn_start, {
      thread_id: id,
      input: inputs(prompt, images),
      model,
      effort,
      cwd: thread.cwd,
      permission_mode,
    }),
  )
  let thread = self.thread(id).unwrap_or(thread)
  if self.revisions.get(id).unwrap_or(0) != before &&
    thread.turn_id is None &&
    thread.status is ("completed" | "failed" | "interrupted") {
    return thread
  }
  let thread = if reply.turn is Some(turn) {
    with_turn(thread, turn, complete=false)
  } else if reply.turn_id is Some(turn_id) {
    { ..thread, turn_id: Some(turn_id), status: "inProgress", }
  } else {
    thread
  }
  self.put(thread)
}

///|
pub async fn State::steer(
  self : State,
  client : @client.Client,
  id : String,
  prompt : String,
  images~ : Array[String] = [],
) -> Thread {
  guard self.thread(id) is Some(thread) && thread.turn_id is Some(turn_id) else {
    raise CodexError("This Codex conversation has no active turn")
  }
  ignore(
    success(
      client.call(@commands.codex_turn_steer, {
        thread_id: id,
        expected_turn_id: turn_id,
        input: inputs(prompt, images),
      }),
    ),
  )
  self.thread(id).unwrap_or(thread)
}

///|
pub async fn State::interrupt(
  self : State,
  client : @client.Client,
  id : String,
) -> Unit {
  guard self.thread(id) is Some(thread) && thread.turn_id is Some(turn_id) else {
    return
  }
  ignore(
    success(
      client.call(@commands.codex_turn_interrupt, { thread_id: id, turn_id, }),
    ),
  )
}

///|
pub async fn State::sync_requests(
  self : State,
  client : @client.Client,
) -> Unit {
  let reply = success(
    client.call(@commands.codex_server_request_list, @protocol.NoPayload),
  )
  self.apply_request_snapshot(reply)
}

///|
pub async fn State::respond(
  self : State,
  client : @client.Client,
  token : String,
  result : Json,
) -> Unit {
  guard self.requests
    .iter()
    .find_first(request => request.response_token == token)
    is Some(request) else {
    raise CodexError("That Codex question is no longer pending")
  }
  ignore(
    success(
      client.call(@commands.codex_server_request_respond, {
        response_token: token,
        request_id: request.request_id,
        result,
      }),
    ),
  )
}

///|
fn inputs(prompt : String, images : Array[String]) -> Array[Json] {
  let result : Array[Json] = []
  if !prompt.is_empty() {
    result.push({ "type": "text", "text": prompt })
  }
  for url in images {
    result.push({ "type": "image", "url": url })
  }
  result
}
