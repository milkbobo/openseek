///|
fn Chat::append_item(self : Chat, event : @protocol.SessionEvent) -> Unit {
  let sequence = Some(event.sequence)
  match event.item {
    @protocol.User(message) => {
      self.rows.push({
        kind: User,
        label: "You",
        text: message.content.text(),
        sequence,
      })
      if self.title == "New chat" {
        self.title = message.content.text()
      }
      if message.submission_id is Some(id) {
        self.pending.remove(id)
        self.queued.remove(id)
        self.steering_drafts.remove(id)
        self.queued_drafts.remove(id)
      }
      self.prediction = None
    }
    @protocol.Assistant(message) => {
      if message.reasoning_content is Some(text) && !text.is_blank() {
        self.rows.push({ kind: Reasoning, label: "Thinking", text, sequence, })
      }
      if !message.content.is_empty() {
        self.rows.push({
          kind: Assistant,
          label: "SeekMoon",
          text: message.content,
          sequence,
        })
      }
      for call in message.tool_calls.unwrap_or([]) {
        self.rows.push({
          kind: Tool(
            @toolcall.Call(call.id, call.name, arguments=call.arguments),
          ),
          label: call.name,
          text: call.arguments,
          sequence,
        })
      }
      self.live_answer = ""
      self.live_reasoning = ""
    }
    @protocol.ToolResult(result) => {
      let status = if result.is_error {
        @toolcall.Failed
      } else {
        @toolcall.Succeeded
      }
      let mut matched = false
      for index, row in self.rows {
        if row.kind is Tool(call) && call.id == result.tool_call_id {
          self.rows[index] = {
            ..row,
            kind: Tool(
              call.finish(result.content.text(), brief?=result.brief, status~),
            ),
          }
          matched = true
          break
        }
      }
      if !matched {
        self.rows.push({
          kind: Tool(
            @toolcall.Call(
              result.tool_call_id,
              result.tool_name,
              output=result.content.text(),
              brief?=result.brief,
              status~,
            ),
          ),
          label: result.tool_name,
          text: "",
          sequence,
        })
      }
    }
    @protocol.RuntimeNotice(notice) => {
      if notice.content.strip_prefix("[goal]\n") is Some(goal) {
        self.goal = Some(goal.to_owned())
      } else if notice.content == "[goal cleared]" {
        self.goal = None
      }
      self.rows.push({
        kind: Notice,
        label: "Activity",
        text: notice.content,
        sequence,
      })
    }
    @protocol.Summary(summary) =>
      self.rows.push({
        kind: Notice,
        label: "Context summary",
        text: summary.content,
        sequence,
      })
    @protocol.Terminal(terminal) => {
      for index, row in self.rows {
        if row.kind is Tool(call) {
          self.rows[index] = { ..row, kind: Tool(call.interrupt()), }
        }
      }
      match terminal {
        Finished(answer) | ContextYield(answer) if !answer.is_empty() =>
          self.rows.push({
            kind: Assistant,
            label: "SeekMoon",
            text: answer,
            sequence,
          })
        _ => ()
      }
      self.live_answer = ""
      self.live_reasoning = ""
      let (status, is_error) = match terminal {
        Finished(_) => ("Completed", false)
        ContextYield(_) => ("Context limit reached", false)
        Aborted(reason) => ("Aborted: \{reason}", true)
        Interrupted(reason) => ("Interrupted: \{reason}", false)
        MaxStepsExhausted => ("Step limit reached", false)
        Failed(reason) => (reason, true)
      }
      self.rows.push({
        kind: if is_error {
          Error
        } else {
          Notice
        },
        label: "Turn",
        text: status,
        sequence,
      })
    }
    @protocol.UnknownTerminal(_) | @protocol.Unknown(_) => ()
  }
}

///|
fn Chat::commit(self : Chat, commit : @protocol.SessionCommitPayload) -> Unit {
  guard commit.session == self.key.session &&
    self.session_root == Some(commit.session_root) else {
    return
  }
  if self.loading || self.needs_reload {
    self.buffered.push(commit)
  } else if commit.sequence > self.watermark + 1 {
    self.needs_reload = true
    self.buffered.push(commit)
  } else if commit.sequence > self.watermark {
    self.append_item(commit.event)
    self.watermark = commit.sequence
  }
}

///|
fn Chat::snapshot(self : Chat, reply : @protocol.LoadSessionReply) -> Unit {
  let live_answer = self.live_answer
  let live_reasoning = self.live_reasoning
  let mut snapshot_watermark = 0
  for event in reply.session.events.unwrap_or([]) {
    snapshot_watermark = snapshot_watermark.max(event.sequence)
  }
  snapshot_watermark = reply.watermark.unwrap_or(snapshot_watermark)
  if snapshot_watermark < self.watermark {
    self.loading = false
    self.needs_reload = true
    self.notice("Session snapshot moved backwards; reloading", error=true)
    return
  }
  self.rows.clear()
  self.goal = None
  for event in reply.session.events.unwrap_or([]) {
    self.append_item(event)
  }
  self.watermark = snapshot_watermark
  self.prediction = reply.prediction
  self.loaded = true
  self.loading = false
  self.needs_reload = false
  if self.run_id is Some(_) {
    self.live_answer = live_answer
    self.live_reasoning = live_reasoning
  }
  self.buffered.sort_by_key(item => item.sequence)
  let remaining : Array[@protocol.SessionCommitPayload] = []
  for commit in self.buffered {
    if commit.sequence <= self.watermark {
      continue
    }
    if self.needs_reload || commit.sequence > self.watermark + 1 {
      self.needs_reload = true
      remaining.push(commit)
    } else {
      self.append_item(commit.event)
      self.watermark = commit.sequence
    }
  }
  self.buffered.clear()
  self.buffered.append(remaining)
}

///|
fn Chat::stream(
  self : Chat,
  event : @agent_protocol.Event,
  run_id~ : String? = None,
) -> Unit {
  match event {
    AssistantDelta(content~) => self.live_answer += content
    ReasoningDelta(content~) => self.live_reasoning += content
    AgentStep(step~) => {
      self.live_answer = ""
      self.live_reasoning = ""
      self.status = "Working · step \{step}"
    }
    StreamRetry(attempt~, max_attempts~, reason~) => {
      self.live_answer = ""
      self.live_reasoning = ""
      self.status = "Retrying \{attempt}/\{max_attempts} · \{reason}"
    }
    Usage(usage~) =>
      self.status = "Working · \{usage.prompt_tokens} input · \{usage.completion_tokens} output tokens"
    SteerApplied(submission_id=Some(id), ..) =>
      self.acknowledge_steer(id, run_id)
    SteerDropped(submission_id~, ..) =>
      if submission_id is Some(id) && self.reject_steer(id, run_id) {
        self.notice("Follow-up was not applied. Resubmit from the composer.")
      }
    GoalUpdated(goal~) => self.goal = goal
    GoalBlocked(reason~) => self.status = "Goal blocked: \{reason}"
    GoalUnblocked => self.status = "Goal resumed"
    SubrunStarted(id~, label~, ..) => self.status = "\{id} · \{label}"
    SubrunFinished(id~, status~, steps~, ..) =>
      self.notice("\{id} · \{status} · \{steps} steps")
    WorkflowStarted(id~, ..) => self.status = "Workflow \{id}"
    WorkflowFinished(id~) => self.notice("Workflow \{id} completed")
    CompactionStarted(..) => self.status = "Compacting context…"
    CompactionFinished(..) => self.status = "Context compacted"
    CompactionFailed(error~) | SessionError(error~) =>
      self.notice(error, error=true)
    BackgroundNotice(content~) => self.notice(content)
    ToolCallDecodeError(tool_name~, error~, ..) =>
      self.notice("\{tool_name}: \{error}", error=true)
    _ => ()
  }
}

///|
fn State::notification(
  self : State,
  notification : @protocol.Notification,
) -> Unit {
  match notification {
    AgentStarted(started) => {
      let chat = if self.chat_for_run(Some(started.run_id)) is Some(chat) {
        Some(chat)
      } else {
        self.chats
        .values()
        .find_first(chat => {
          chat.key.session == started.session &&
          (
            chat.session_root == started.session_root ||
            chat.session_root is None
          )
        })
      }
      if chat is Some(chat) {
        chat.lifecycle_generation += 1
        chat.run_id = Some(started.run_id)
        chat.session_root = started.session_root
        chat.status = "Working"
        if started.submission_id is Some(id) &&
          chat.queued.get(id) is Some(text) {
          chat.queued.remove(id)
          chat.pending[id] = text
        }
      }
    }
    AgentEvent(payload) => {
      let chat = if self.chat_for_run(payload.run_id) is Some(chat) {
        Some(chat)
      } else {
        self.unique_session(payload.session)
      }
      if chat is Some(chat) {
        chat.stream(payload.event, run_id=payload.run_id)
      }
    }
    SessionEvent(commit) =>
      for chat in self.chats.values() {
        chat.commit(commit)
      }
    AgentFinished(finished) =>
      if self.chat_for_run(Some(finished.run_id)) is Some(chat) {
        chat.forget_steers_for_run(finished.run_id)
        chat.lifecycle_generation += 1
        chat.run_id = None
        chat.status = finished.status
        chat.live_answer = ""
        chat.live_reasoning = ""
      }
    AgentError(error) => {
      let chat = self.chat_for_run(error.run_id).unwrap_or(self.active)
      chat.notice(error.message.unwrap_or("Agent failed"), error=true)
      if error.diagnostics is Some(text) && !text.is_blank() {
        chat.notice(text, error=true)
      }
    }
    AgentPrediction(ready) =>
      if self.unique_session(ready.session) is Some(chat) {
        chat.prediction = Some(ready.prediction)
      }
    AgentApprovals(snapshot) =>
      if snapshot.generation >= self.approval_generation {
        self.approvals = snapshot.approvals
        self.approval_generation = snapshot.generation
      }
    SettingsChanged(settings) => self.apply_settings(settings)
    SubrunProgress(progress) =>
      if self.unique_session(progress.session) is Some(chat) {
        chat.status = "\{progress.id} · step \{progress.steps} · \{progress.activity}"
      }
    TerminalExit(exit) => self.terminal_exited(exit)
    CodexNotification(notification) =>
      if self.codex.apply(notification) is Some(thread) {
        self.install_codex(thread)
      }
    CodexServerRequest(request) =>
      if self.codex.apply_request(request) {
        self.notice = "Codex needs an answer · /codex requests"
      }
    _ => ()
  }
}
