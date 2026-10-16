///|
/// Notification and settings frontiers are process-local at the server. A new
/// socket may join a restarted host whose counters begin at zero again.
fn State::begin_connection(self : State) -> Unit {
  self.approvals = []
  self.approval_generation = -1
  self.settings = None
  self.resync_needed = false
  self.codex.begin_connection()
  for chat in self.chats.values() {
    if chat.codex_id() is Some(_) {
      chat.run_id = None
      chat.status = "Reconnecting"
    }
  }
}

///|
fn State::defer_startup_submission(self : State, text : String) -> Unit {
  if text.is_blank() && self.active.attachments.is_empty() {
    return
  }
  if self.startup_submission is None {
    self.startup_submission = Some((self.active, text))
  }
}

///|
/// Do not submit to a different conversation or send a draft edited since
/// Enter. The draft stays editable while startup is fetching its catalog.
fn State::take_startup_submission(self : State) -> String? {
  let pending = self.startup_submission
  self.startup_submission = None
  guard pending is Some((chat, text)) else { return None }
  if physical_equal(chat, self.active) && chat.draft.text() == text {
    Some(text)
  } else {
    self.notice = "Selection or draft changed · press Enter to send"
    None
  }
}
