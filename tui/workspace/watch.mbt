///|
async fn State::watch(self : State, client : @client.Client) -> Unit {
  guard self.root is Some(root) else { return }
  let generation = "tui-workspace-\{self.generation}"
  self.watch_generation = Some(generation)
  let prefix = root.trim_end(chars="/").to_owned() + "/"
  let files = self.tabs
    .iter()
    .filter_map(tab => {
      tab.path.strip_prefix(prefix).map(path => path.to_owned())
    })
    .collect()
  ignore(
    client.call(@commands.fs_watch, @protocol.WatchWorkspacePayload::{
      path: root,
      files,
      directories: [""],
      recursive: Some(true),
      generation,
    }),
  )
}

///|
async fn expanded_children(
  client : @client.Client,
  root : String,
  depth : Int32,
  expanded : Array[String],
) -> Array[TreeItem] {
  let rows = children(client, root, depth)
  let result = []
  for item in rows {
    result.push(item)
    if item.is_dir && expanded.contains(item.path) {
      result.append(expanded_children(client, item.path, depth + 1, expanded))
    }
  }
  result
}

///|
async fn State::refresh_tree(self : State, client : @client.Client) -> Unit {
  guard self.root is Some(root) else { return }
  let generation = self.generation
  let selected = self.tree.get(self.selected).map(item => item.path)
  let expanded = self.tree
    .mapi((index, item) => {
      if item.is_dir &&
        self.tree
        .get(index + 1)
        .map(next => next.depth > item.depth)
        .unwrap_or(false) {
        Some(item.path)
      } else {
        None
      }
    })
    .iter()
    .filter_map(item => item)
    .collect()
  let rows = expanded_children(client, root, 0, expanded)
  if generation != self.generation {
    return
  }
  self.tree = rows
  self.selected = if selected is Some(path) {
    rows
    .search_by(item => item.path == path)
    .unwrap_or(self.selected.min((rows.length() - 1).max(0)))
  } else {
    0
  }
}

///|
fn Tab::reload(self : Tab, content : String) -> Unit {
  let (line, col) = self.editor.position()
  self.editor.set_text(content)
  self.editor.move_to_start()
  // Preserve the caret's source line and display column after an agent edit.
  for _ in 0..<line {
    self.editor.move_end()
    self.editor.move_right()
  }
  while self.editor.position().0 == line && self.editor.position().1 < col {
    let before = self.editor.position()
    self.editor.move_right()
    if before == self.editor.position() {
      break
    }
  }
  self.baseline = Some(content)
  self.external_changed = false
  self.undo.clear()
  self.redo.clear()
}

///|
/// Apply the connection-owned workspace watcher. Baselines also repair files
/// changed while the client was disconnected. Dirty editors keep their drafts;
/// their original baseline makes a conflicting save fail at the shared server.
pub async fn State::notification(
  self : State,
  client : @client.Client,
  event : @protocol.Notification,
) -> Unit {
  match event {
    FsWatchFailed(payload) if self.root == Some(payload.root) &&
      self.watch_generation == Some(payload.generation) =>
      self.message = "File watcher failed: " + payload.message
    FsChanged(payload) if self.root == Some(payload.root) &&
      self.watch_generation == Some(payload.generation) => {
      let generation = self.generation
      self.refresh_tree(client)
      for tab in self.tabs.copy() {
        if generation != self.generation {
          return
        }
        let prefix = payload.root.trim_end(chars="/").to_owned() + "/"
        guard tab.path.strip_prefix(prefix) is Some(relative) else { continue }
        guard payload.baseline ||
          payload.events
          .iter()
          .any(event => {
            event.path == relative.to_owned() ||
            event.old_path == Some(relative.to_owned())
          }) else {
          continue
        }
        let baseline = tab.baseline
        let reply = client.call(@commands.fs_read_file, @protocol.ReadFilePayload::{
          path: tab.path,
          root: None,
        }) catch {
          error if @async.is_being_cancelled() => raise error
          error => {
            tab.external_changed = true
            self.message = "Cannot refresh " +
              tab.path +
              ": " +
              error.to_string()
            continue
          }
        }
        if generation != self.generation {
          return
        }
        if reply is Content(content~, ..) {
          if tab.baseline != baseline {
            continue
          }
          if !tab.dirty() {
            if baseline != Some(content) {
              tab.reload(content)
            }
          } else {
            tab.external_changed = baseline != Some(content)
          }
        } else {
          tab.external_changed = true
          self.message = "File is no longer an editable text file: " + tab.path
        }
      }
    }
    _ => ()
  }
}

///|
/// Invalidate the selected tree immediately while another checkout is being
/// resolved. Explicit file tabs remain available with their original paths.
pub fn State::clear(self : State) -> Unit {
  self.generation += 1
  self.watch_generation = None
  self.root = None
  self.context = None
  self.tree = []
  self.selected = 0
  self.top = 0
  self.creating = false
  self.message = "Choose a project to browse files"
}
