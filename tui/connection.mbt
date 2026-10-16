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
