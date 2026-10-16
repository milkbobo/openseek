///|
priv struct Tab {
  path : String
  context : @workbench.Context
  editor : @editor.Editor
  original : @editor.Editor
  mut baseline : String?
  mut external_changed : Bool
  mut diff : Bool
  mut unified : Bool
  diff_scroll : @tui.Scroll
  undo : Array[String]
  redo : Array[String]
}

///|
priv struct TreeItem {
  path : String
  name : String
  depth : Int32
  is_dir : Bool
}

///|
/// File tabs and the project explorer belonging to one terminal workspace.
struct State {
  tabs : Array[Tab]
  mut active : Int32
  mut tree : Array[TreeItem]
  expanded : Set[String]
  mut selected : Int32
  mut top : Int32
  mut root : String?
  mut context : @workbench.Context?
  mut tree_focused : Bool
  mut message : String
  mut generation : Int32
  mut watch_generation : String?
  mut tree_area : @tui.Rect
  mut editor_area : @tui.Rect
  naming : @editor.Editor
  mut creating : Bool
}

///|
pub fn State::State() -> State {
  {
    tabs: [],
    active: 0,
    tree: [],
    expanded: Set([]),
    selected: 0,
    top: 0,
    root: None,
    context: None,
    tree_focused: false,
    message: "click Editor above · Ctrl+R files",
    generation: 0,
    watch_generation: None,
    tree_area: @tui.Rect(row=0, col=0, width=0, height=0),
    editor_area: @tui.Rect(row=0, col=0, width=0, height=0),
    naming: @editor.Editor(),
    creating: false,
  }
}

///|
pub fn State::has_tabs(self : State) -> Bool {
  !self.tabs.is_empty()
}

///|
pub fn State::title(self : State) -> String {
  self.tabs.get(self.active).map(tab => tab.path).unwrap_or("Workspace")
}

///|
pub fn State::status(self : State) -> String {
  self.message
}

///|
pub fn State::focus_tree(self : State) -> Unit {
  self.tree_focused = true
}

///|
pub fn State::focus_editor(self : State) -> Unit {
  self.tree_focused = false
}

///|
fn Tab::dirty(self : Tab) -> Bool {
  self.baseline.map(text => text != self.editor.text()).unwrap_or(true)
}

///|
fn Tab::remember(self : Tab, before : String) -> Unit {
  if before == self.editor.text() {
    return
  }
  if self.undo.length() >= 100 {
    ignore(self.undo.remove(0))
  }
  self.undo.push(before)
  self.redo.clear()
}

///|
fn filename(path : String) -> String {
  path.split("/").last().map(part => part.to_owned()).unwrap_or(path)
}

///|
async fn checkout(
  client : @client.Client,
  context : @workbench.Context,
) -> String {
  guard context.workspace is Some(root) else {
    fail("Choose a project to browse files")
  }
  let reply = client.call(@commands.worktree_list, @protocol.WorktreeListPayload::{
    workspace: root,
  })
  if reply.worktrees
    .iter()
    .find_first(tree => {
      if context.codex_thread is Some(id) {
        tree.codex_thread == Some(id)
      } else {
        tree.sessions.contains(context.session)
      }
    })
    is Some(tree) {
    guard tree.present else {
      fail("Repair this conversation's missing worktree first")
    }
    tree.path
  } else {
    root
  }
}

///|
async fn children(
  client : @client.Client,
  root : String,
  depth : Int32,
) -> Array[TreeItem] {
  let reply = client.call(@commands.fs_read_directory, @protocol.ReadDirPayload::{
    path: root,
  })
  let entries = reply.entries.copy()
  entries.sort_by((one, two) => {
    if one.is_dir != two.is_dir {
      if one.is_dir {
        -1
      } else {
        1
      }
    } else {
      one.name.lexical_compare(two.name)
    }
  })
  entries.map(entry => {
    path: root.trim_end(chars="/").to_owned() + "/" + entry.name,
    name: entry.name,
    depth,
    is_dir: entry.is_dir,
  })
}

///|
/// Refresh the explorer from the selected conversation's actual checkout.
pub async fn State::browse(
  self : State,
  client : @client.Client,
  context : @workbench.Context,
) -> Unit {
  self.generation += 1
  let generation = self.generation
  let root = checkout(client, context)
  let rows = children(client, root, 0)
  if generation != self.generation {
    return
  }
  self.root = Some(root)
  self.context = Some(context)
  self.tree = rows
  self.expanded.clear()
  self.selected = 0
  self.top = 0
  self.message = root
  self.watch(client)
}

///|
/// Open an existing UTF-8 file in an editable tab. A diff tab also reads its
/// immutable Git original; saving still compares against the loaded disk text.
pub async fn State::open(
  self : State,
  client : @client.Client,
  context : @workbench.Context,
  path : String,
  diff~ : Bool = false,
) -> Unit {
  let root = checkout(client, context)
  let relative = path
    .strip_prefix(root.trim_end(chars="/").to_owned() + "/")
    .map(part => part.to_owned())
    .unwrap_or(path)
  let changes = if diff {
    Some(
      client.call(@commands.git_changes, {
        session: context.session,
        workspace: context.workspace,
      }),
    )
  } else {
    None
  }
  let change = changes.bind(changes => {
    changes.changes.iter().find_first(change => change.path == relative)
  })
  let deleted = change is Some({ kind: "deleted", .. })
  let (content, absolute) = if deleted {
    ("", root.trim_end(chars="/").to_owned() + "/" + relative)
  } else {
    let reply = client.call(@commands.fs_read_file, @protocol.ReadFilePayload::{
      path,
      root: if path.has_prefix("/") {
        None
      } else {
        Some(root)
      },
    })
    match reply {
      Content(content~, absolute~, ..) => (content, absolute)
      Binary | BinaryContent(..) =>
        fail(
          "This file is binary; use its desktop preview or a terminal viewer",
        )
      Oversized => fail("This file exceeds the editor's text preview limit")
    }
  }
  let tab = if self.tabs.search_by(tab => tab.path == absolute) is Some(index) {
    self.active = index
    self.tabs[index]
  } else {
    let editor = @editor.Editor(text=content, preserve_text=true)
    editor.move_to_start()
    let tab : Tab = {
      path: absolute,
      context,
      editor,
      original: @editor.Editor(preserve_text=true),
      baseline: if deleted {
        None
      } else {
        Some(content)
      },
      external_changed: false,
      diff: false,
      unified: false,
      diff_scroll: @tui.Scroll(),
      undo: [],
      redo: [],
    }
    self.tabs.push(tab)
    self.active = self.tabs.length() - 1
    tab
  }
  if diff {
    let original = client.call(@commands.git_original_file, @protocol.GitOriginalFilePayload::{
      session: context.session,
      workspace: context.workspace,
      path: change.bind(change => change.original_path).unwrap_or(relative),
      revision: changes.bind(changes => {
        if changes.baseline is Some(base) {
          Some(base)
        } else {
          changes.head
        }
      }),
    })
    let source = match original {
      OriginalContent(text) => text
      Missing => ""
      BinaryOriginal => fail("The Git original is binary")
      OversizedOriginal =>
        fail("The Git original exceeds the diff preview limit")
    }
    tab.original.set_text(source)
    tab.original.move_to_start()
    tab.diff = true
    tab.unified = false
  }
  self.watch(client)
  self.tree_focused = false
  self.message = if diff {
    "Diff · Ctrl+D preview/edit · Ctrl+S save"
  } else {
    "Ctrl+S save · Ctrl+Z undo · Alt+Left/Right tabs"
  }
}

///|
async fn State::save(self : State, client : @client.Client) -> Unit {
  guard self.tabs.get(self.active) is Some(tab) else { return }
  let content = tab.editor.text()
  ignore(
    client.call(@commands.fs_write_file, @protocol.WriteFilePayload::{
      session: tab.context.session,
      root: None,
      path: tab.path,
      content,
      expected_content: tab.baseline,
    }),
  )
  tab.baseline = Some(content)
  tab.external_changed = false
  self.message = "Saved " + tab.path
}

///|
async fn State::activate_tree(
  self : State,
  client : @client.Client,
  context : @workbench.Context,
) -> Unit {
  guard self.tree.get(self.selected) is Some(item) else { return }
  if item.is_dir {
    let start = self.selected + 1
    let mut end = start
    while end < self.tree.length() && self.tree[end].depth > item.depth {
      end += 1
    }
    if self.expanded.contains(item.path) {
      self.tree = [..self.tree[:start], ..self.tree[end:]]
      for path in self.expanded.to_array() {
        if path == item.path || path.has_prefix(item.path + "/") {
          self.expanded.remove(path)
        }
      }
    } else {
      let nested = children(client, item.path, item.depth + 1)
      self.expanded.add(item.path)
      self.tree = [..self.tree[:start], ..nested, ..self.tree[start:]]
    }
    self.watch(client)
  } else {
    self.open(client, context, item.path)
  }
}

///|
pub fn State::paste(self : State, text : StringView) -> Bool {
  if self.creating {
    self.naming.insert(text)
    return true
  }
  if self.tree_focused {
    return false
  }
  guard self.tabs.get(self.active) is Some(tab) else { return false }
  if tab.unified {
    return true
  }
  let before = tab.editor.text()
  tab.editor.insert(text)
  tab.remember(before)
  true
}

///|
pub async fn State::key(
  self : State,
  client : @client.Client,
  key : @input.KeyEvent,
) -> Bool {
  if key.kind is Release {
    return false
  }
  if self.creating {
    if key.code is Escape {
      self.creating = false
      return true
    }
    if key.code is Enter {
      guard self.root is Some(root) && self.context is Some(context) else {
        return true
      }
      let name = self.naming.text().trim().to_owned()
      guard !name.is_empty() else { return true }
      let path = root.trim_end(chars="/").to_owned() + "/" + name
      self.tabs.push({
        path,
        context,
        editor: @editor.Editor(preserve_text=true),
        original: @editor.Editor(preserve_text=true),
        baseline: None,
        external_changed: false,
        diff: false,
        unified: false,
        diff_scroll: @tui.Scroll(),
        undo: [],
        redo: [],
      })
      self.active = self.tabs.length() - 1
      self.creating = false
      self.tree_focused = false
      self.message = "New file · Ctrl+S creates " + path
      self.watch(client)
      return true
    }
    return self.naming.key(key)
  }
  if key.modifiers.ctrl() && key.code is Char('s') {
    self.save(client) catch {
      error if @async.is_being_cancelled() => raise error
      error => self.message = "Save failed: " + error.to_string()
    }
    return true
  }
  if key.modifiers.alt() && key.code is (Left | Right) && !self.tabs.is_empty() {
    let step = if key.code is Left { -1 } else { 1 }
    self.active = (self.active + step + self.tabs.length()) % self.tabs.length()
    self.tree_focused = false
    return true
  }
  if self.tree_focused {
    match key.code {
      Up => self.selected = (self.selected - 1).max(0)
      Down =>
        self.selected = (self.selected + 1).min((self.tree.length() - 1).max(0))
      PageUp =>
        self.selected = (self.selected - self.tree_area.height.max(1)).max(0)
      PageDown =>
        self.selected = (self.selected + self.tree_area.height.max(1)).min(
          (self.tree.length() - 1).max(0),
        )
      Home => self.selected = 0
      End => self.selected = (self.tree.length() - 1).max(0)
      Enter | Right =>
        if self.context is Some(context) {
          self.activate_tree(client, self.context.unwrap_or(context))
        }
      Left =>
        if self.tree.get(self.selected) is Some(item) && item.depth > 0 {
          let mut parent = self.selected - 1
          while parent > 0 && self.tree[parent].depth >= item.depth {
            parent -= 1
          }
          self.selected = parent
        }
      Char('d') if !key.modifiers.ctrl() =>
        if self.tree.get(self.selected) is Some(item) &&
          !item.is_dir &&
          self.context is Some(context) {
          self.open(client, context, item.path, diff=true)
        }
      Char('n') if !key.modifiers.ctrl() => {
        self.creating = true
        self.naming.clear()
        self.message = "New file path, relative to project root"
      }
      _ => return false
    }
    let height = (self.tree_area.height - 1).max(0)
    if self.selected < self.top {
      self.top = self.selected
    }
    if self.selected >= self.top + height && height > 0 {
      self.top = self.selected - height + 1
    }
    return true
  }
  guard self.tabs.get(self.active) is Some(tab) else { return false }
  if key.modifiers.ctrl() && key.code is Char('d') && tab.diff {
    tab.unified = !tab.unified
    return true
  }
  if key.modifiers.ctrl() && key.code is Char('w') {
    if tab.dirty() && !key.modifiers.shift() {
      self.message = "Unsaved file · Ctrl+S save, Ctrl+Shift+W discard"
    } else {
      ignore(self.tabs.remove(self.active))
      self.active = self.active.min((self.tabs.length() - 1).max(0))
      self.watch(client)
    }
    return true
  }
  if tab.unified {
    match key.code {
      Up => tab.diff_scroll.scroll_by(-1)
      Down => tab.diff_scroll.scroll_by(1)
      PageUp => tab.diff_scroll.page_up()
      PageDown => tab.diff_scroll.page_down()
      Home => tab.diff_scroll.to_top()
      End => tab.diff_scroll.to_bottom()
      _ => ()
    }
    return true
  }
  if key.modifiers.ctrl() && key.code is Char('z') && !key.modifiers.shift() {
    if tab.undo.pop() is Some(text) {
      tab.redo.push(tab.editor.text())
      tab.editor.set_text(text)
    }
    return true
  }
  if key.modifiers.ctrl() &&
    (key.code is Char('y') || (key.code is Char('z') && key.modifiers.shift())) {
    if tab.redo.pop() is Some(text) {
      tab.undo.push(tab.editor.text())
      tab.editor.set_text(text)
    }
    return true
  }
  let before = tab.editor.text()
  let used = if key.code is Enter ||
    (key.modifiers.ctrl() && key.code is Char('j')) {
    tab.editor.insert(
      if tab.baseline.map(text => text.contains("\r\n")).unwrap_or(false) {
        "\r\n"
      } else {
        "\n"
      },
    )
    true
  } else if key.code is Tab {
    tab.editor.insert("\t")
    true
  } else {
    tab.editor.key(key)
  }
  tab.remember(before)
  used
}

///|
fn contains(area : @tui.Rect, row : Int32, col : Int32) -> Bool {
  row >= area.row &&
  col >= area.col &&
  row < area.row + area.height &&
  col < area.col + area.width
}

///|
pub async fn State::mouse(
  self : State,
  client : @client.Client,
  mouse : @input.MouseEvent,
  context : @workbench.Context,
) -> Bool {
  let row = mouse.row - 1
  let mouse_col = mouse.col - 1
  if contains(self.tree_area, row, mouse_col) {
    self.tree_focused = true
    match mouse.kind {
      Press(Left) if row > self.tree_area.row => {
        let index = self.top + row - self.tree_area.row - 1
        if index >= 0 && index < self.tree.length() {
          self.selected = index
          self.activate_tree(client, self.context.unwrap_or(context))
        }
      }
      Scroll(Down) =>
        self.top = (self.top + 3).min((self.tree.length() - 1).max(0))
      Scroll(Up) => self.top = (self.top - 3).max(0)
      _ => ()
    }
    return true
  }
  if contains(self.editor_area, row, mouse_col) {
    self.tree_focused = false
    if row == self.editor_area.row && mouse.kind is Press(Left) {
      let mut col = self.editor_area.col
      for index, tab in self.tabs {
        col += @tui.Line::from_text(
          " " + filename(tab.path) + (if tab.dirty() { " ● " } else { " " }),
        ).width()
        if mouse_col < col {
          self.active = index
          return true
        }
      }
    }
    if self.tabs.get(self.active) is Some(tab) {
      if tab.unified {
        match mouse.kind {
          Scroll(Up) => tab.diff_scroll.scroll_by(-3)
          Scroll(Down) => tab.diff_scroll.scroll_by(3)
          _ => ()
        }
        return true
      }
      return tab.editor.mouse(mouse)
    }
    return true
  }
  false
}

///|
pub fn State::draw_tree(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  focused~ : Bool = false,
) -> Unit {
  self.tree_area = area
  if area.width == 0 || area.height == 0 {
    return
  }
  frame.fill(area, style=@tui.Style(bg=Rgb(20, 25, 34)))
  frame.line(
    @tui.Rect(row=area.row, col=area.col, width=area.width, height=1),
    @tui.Line::from_text(
      " FILES · d diff · n +",
      style=@tui.Style(bold=true, fg=Rgb(160, 177, 198)),
    ),
  )
  let height = (area.height - 1).max(0)
  self.top = self.top.min((self.tree.length() - height).max(0))
  for index in self.top..<(self.top + height).min(self.tree.length()) {
    let item = self.tree[index]
    let expanded = self.tree
      .get(index + 1)
      .map(next => next.depth > item.depth)
      .unwrap_or(false)
    let prefix = if item.is_dir {
      if expanded {
        "▾ "
      } else {
        "▸ "
      }
    } else {
      "  "
    }
    let indent = Array::make(item.depth, "  ").join("")
    let selected = index == self.selected
    let style = @tui.Style(
      fg=if item.is_dir { Rgb(126, 180, 234) } else { Rgb(204, 212, 223) },
      bg=if selected && focused && self.tree_focused {
        Rgb(45, 65, 87)
      } else {
        Rgb(20, 25, 34)
      },
      bold=item.is_dir,
    )
    frame.line(
      @tui.Rect(
        row=area.row + 1 + index - self.top,
        col=area.col,
        width=area.width,
        height=1,
      ),
      @tui.Line::from_text(indent + prefix + item.name, style~),
    )
  }
}

///|
pub fn State::draw_editor(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  focused~ : Bool = false,
) -> Unit {
  self.editor_area = area
  if area.width == 0 || area.height == 0 {
    return
  }
  frame.fill(area, style=@tui.Style(bg=Rgb(17, 22, 30)))
  let header = @tui.Rect(row=area.row, col=area.col, width=area.width, height=1)
  let body = @tui.Rect(
    row=area.row + 1,
    col=area.col,
    width=area.width,
    height=(area.height - 2).max(0),
  )
  let footer = @tui.Rect(
    row=area.row + (area.height - 1).max(0),
    col=area.col,
    width=area.width,
    height=1,
  )
  if self.creating {
    frame.line(
      header,
      @tui.Line::from_text(" New file · Enter create · Esc cancel"),
    )
    self.naming.draw(frame, body, focused~)
    return
  }
  let spans = self.tabs.mapi((index, tab) => {
    @tui.Span(
      " " + filename(tab.path) + (if tab.dirty() { " ● " } else { " " }),
      style=@tui.Style(
        fg=if index == self.active {
          Rgb(224, 234, 248)
        } else {
          Rgb(130, 145, 165)
        },
        bg=if index == self.active { Rgb(40, 52, 69) } else { Rgb(23, 29, 39) },
      ),
    )
  })
  frame.line(header, @tui.Line(spans))
  if self.tabs.get(self.active) is Some(tab) {
    if tab.diff {
      tab.draw_diff(frame, body, focused && !self.tree_focused)
    } else {
      tab.editor.draw(
        frame,
        body,
        focused=focused && !self.tree_focused,
        highlight?=@highlight.for_path(tab.path),
        line_numbers=@tui.Style(fg=Rgb(88, 105, 127)),
        current_line=@tui.Style(bg=Rgb(26, 34, 46)),
      )
    }
  } else {
    frame.lines(body, [
      @tui.Line::from_text("Open a file from the explorer"),
      @tui.Line::from_text("Ctrl+R files · click Editor above"),
      @tui.Line::from_text("n creates a new file"),
      @tui.Line::from_text("/diff PATH opens a Git diff"),
    ])
  }
  frame.line(
    footer,
    @tui.Line::from_text(
      if self.tabs
        .get(self.active)
        .map(tab => tab.external_changed)
        .unwrap_or(false) {
        "File changed on disk · save will report a conflict · " + self.message
      } else {
        self.message
      },
      style=@tui.Style(fg=Rgb(130, 150, 174)),
    ),
  )
}
