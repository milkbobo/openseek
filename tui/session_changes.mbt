///|
/// Apply another client's archive/delete fact before any asynchronous list or
/// transcript refresh. It invalidates reads already in flight for the old
/// store, matching the Desktop's identity-bearing session invalidation.
fn State::session_changed(
  self : State,
  change : @protocol.SessionChangedPayload,
) -> Unit {
  let matches = self.chats
    .values()
    .filter(chat => {
      chat.key.session == change.session &&
      chat.key.workspace == Some(change.workspace)
    })
    .collect()
  if matches.is_empty() {
    return
  }
  for chat in matches {
    chat.snapshot_generation += 1
    chat.lifecycle_generation += 1
    chat.loading = false
    chat.needs_reload = true
    chat.buffered.clear()
  }
  if change.change == "deleted" {
    let selected = matches.any(chat => physical_equal(chat, self.active))
    for chat in matches {
      self.chats.remove(chat.key)
    }
    self.sidebar = self.sidebar.filter(key => {
      key.session != change.session || key.workspace != Some(change.workspace)
    })
    if selected {
      self.new_chat(Some(change.workspace))
      self.workspace.clear()
      self.notice = "This conversation was deleted by another client"
    }
    return
  }
  guard change.change is ("archived" | "unarchived") else { return }
  let chat = matches
    .iter()
    .find_first(chat => physical_equal(chat, self.active))
    .unwrap_or(matches[0])
  for previous in matches {
    self.chats.remove(previous.key)
  }
  chat.key = { ..chat.key, archived: change.change == "archived", }
  chat.session_root = None
  chat.run_id = None
  chat.status = if chat.key.archived { "Archived" } else { "Ready" }
  self.chats[chat.key] = chat
  let keys : Array[ChatKey] = []
  for key in self.sidebar {
    let key = if key.session == change.session &&
      key.workspace == Some(change.workspace) {
      chat.key
    } else {
      key
    }
    if !keys.contains(key) {
      keys.push(key)
    }
  }
  self.sidebar = keys
  self.reveal_sidebar_chat(self.active.key)
}
