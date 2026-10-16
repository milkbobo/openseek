///|
enum SidebarMode {
  ChatsMode
  ProjectsMode
}

///|
enum SidebarEntry {
  SidebarChat(ChatKey)
  SidebarProject(String?, Int32, Bool)
  SidebarHint(String)
}

///|
fn State::sidebar_paste(self : State, text : StringView) -> Bool {
  if self.project_entry is Some(editor) {
    editor.insert(text)
    true
  } else {
    false
  }
}

///|
fn State::sidebar_rows(self : State) -> Array[SidebarEntry] {
  if self.sidebar_mode is ChatsMode {
    return self.sidebar.map(key => SidebarChat(key))
  }
  let projects = self.projects.map(path => Some(path))
  for key in self.sidebar {
    if !projects.contains(key.workspace) {
      projects.push(key.workspace)
    }
  }
  let rows : Array[SidebarEntry] = []
  for project in projects {
    let keys = self.sidebar.filter(key => key.workspace == project)
    let expanded = !self.collapsed_projects.contains(project.unwrap_or(""))
    rows.push(SidebarProject(project, keys.length(), expanded))
    if expanded {
      for key in keys {
        rows.push(SidebarChat(key))
      }
      if keys.is_empty() {
        rows.push(SidebarHint("  No chats yet · + starts one"))
      }
    }
  }
  if rows.is_empty() {
    rows.push(SidebarHint("Add a project using +"))
  }
  rows
}

///|
async fn State::refresh_sidebar_projects(
  self : State,
  client : @client.Client,
) -> Unit {
  match client.call(@commands.workspace_list, @protocol.NoPayload) {
    Workspaces(paths, ..) => self.projects = paths
    WorkspaceError(message) => self.notice = message
  }
}

///|
fn State::sidebar_move(self : State, delta : Int32) -> Unit {
  self.sidebar_cursor = (self.sidebar_cursor + delta).clamp(
    min=0,
    max=(self.sidebar_rows().length() - 1).max(0),
  )
}

///|
fn State::reveal_sidebar_chat(self : State, key : ChatKey) -> Unit {
  self.collapsed_projects.remove(key.workspace.unwrap_or(""))
  for index, entry in self.sidebar_rows() {
    if entry is SidebarChat(candidate) && candidate == key {
      self.sidebar_cursor = index
      break
    }
  }
}

///|
async fn State::sidebar_open(self : State, client : @client.Client) -> Unit {
  if self.sidebar_rows().get(self.sidebar_cursor) is Some(entry) {
    match entry {
      SidebarChat(key) =>
        if self.chats.get(key) is Some(chat) {
          self.sidebar_index = self.sidebar.search(key).unwrap_or(0)
          self.load_chat(client, chat)
        }
      SidebarProject(path, _, _) => {
        let key = path.unwrap_or("")
        if self.collapsed_projects.contains(key) {
          self.collapsed_projects.remove(key)
        } else {
          self.collapsed_projects.add(key)
        }
      }
      SidebarHint(_) => ()
    }
  }
}

///|
async fn State::sidebar_key(
  self : State,
  client : @client.Client,
  key : @input.KeyEvent,
) -> Bool {
  guard self.focus is Sidebar else { return false }
  if self.project_entry is Some(editor) {
    if key.code is Escape {
      self.project_entry = None
    } else if key.code is Enter {
      let path = editor.text().trim().to_owned()
      if !path.is_empty() {
        match client.call(@commands.workspace_add, { path, }) {
          Workspaces(paths, ..) => {
            self.projects = paths
            self.project_entry = None
            self.sidebar_mode = ProjectsMode
            self.sidebar_cursor = 0
            self.notice = "Project added"
          }
          WorkspaceError(message) => self.notice = message
        }
      }
    } else {
      ignore(editor.key(key))
    }
    return true
  }
  match key.code {
    Up => self.sidebar_move(-1)
    Down => self.sidebar_move(1)
    Enter => self.sidebar_open(client)
    Left | Char('c') => {
      self.sidebar_mode = ChatsMode
      self.sidebar_cursor = self.sidebar_index
    }
    Right | Char('p') => {
      self.sidebar_mode = ProjectsMode
      self.sidebar_cursor = 0
      self.refresh_sidebar_projects(client)
    }
    Char('+') => {
      self.project_entry = Some(@editor.Editor())
      self.notice = "Enter an absolute project path, then press Enter"
    }
    Char('n') =>
      if self.sidebar_rows().get(self.sidebar_cursor)
        is Some(SidebarProject(path, _, _)) {
        self.start_chat(client, path)
      } else {
        self.start_chat(client, self.active.key.workspace)
      }
    _ => return false
  }
  true
}

///|
async fn State::sidebar_mouse(
  self : State,
  client : @client.Client,
  mouse : @input.MouseEvent,
  regions : Regions,
) -> Bool {
  let row = mouse.row - 1
  let col = mouse.col - 1
  if regions.left.width <= 0 || !contains_point(regions.left, row, col) {
    return false
  }
  if mouse.kind is Press(Left) && row == regions.left.row + 2 {
    self.focus = Sidebar
    if col >= regions.left.col + regions.left.width - 3 {
      self.project_entry = Some(@editor.Editor())
      self.notice = "Enter an absolute project path, then press Enter"
    } else if col < regions.left.col + 9 {
      self.sidebar_mode = ChatsMode
      self.sidebar_cursor = self.sidebar_index
    } else {
      self.sidebar_mode = ProjectsMode
      self.sidebar_cursor = 0
      self.refresh_sidebar_projects(client)
    }
    return true
  }
  if mouse.kind is Press(Left) &&
    self.project_entry is Some(_) &&
    row == regions.left.row + 3 {
    self.focus = Sidebar
    return true
  }
  guard contains_point(regions.left_chats, row, col) else { return false }
  if mouse.kind is Scroll(direction) {
    self.sidebar_move(if direction is Up { -3 } else { 3 })
    return true
  }
  if mouse.kind is Press(Left) {
    self.focus = Sidebar
    let cursor = self.sidebar_cursor.min(
      (self.sidebar_rows().length() - 1).max(0),
    )
    let top = (cursor - regions.left_chats.height + 1).max(0)
    self.sidebar_cursor = top + row - regions.left_chats.row
    if self.sidebar_rows().get(self.sidebar_cursor)
      is Some(SidebarProject(path, _, _)) &&
      col >= regions.left.col + regions.left.width - 3 {
      self.start_chat(client, path)
    } else {
      self.sidebar_open(client)
    }
    return true
  }
  false
}

///|
fn State::draw_sidebar(
  self : State,
  frame : @tui.Frame,
  regions : Regions,
) -> Unit {
  let area = regions.left
  if area.width == 0 {
    return
  }
  frame.fill(area, style=@tui.Style(bg=Rgb(22, 28, 38)))
  frame.line(area, @tui.Line::from_text(" + New chat      ^N", style=accent()))
  let tabs = @tui.Rect(
    row=area.row + 2,
    col=area.col,
    width=area.width,
    height=1,
  )
  frame.line(
    tabs,
    @tui.Line([
      @tui.Span(
        " Chats ",
        style=if self.sidebar_mode is ChatsMode { accent() } else { muted() },
      ),
      @tui.Span(
        " Projects ",
        style=if self.sidebar_mode is ProjectsMode { accent() } else { muted() },
      ),
      @tui.Span(" +", style=accent()),
    ]),
  )
  if self.project_entry is Some(editor) {
    editor.draw(
      frame,
      @tui.Rect(
        row=area.row + 3,
        col=area.col + 1,
        width=(area.width - 2).max(0),
        height=1,
      ),
      focused=self.focus is Sidebar,
      style=@tui.Style(bg=Rgb(34, 42, 57)),
    )
  }
  let entries = self.sidebar_rows()
  let list = regions.left_chats
  let cursor = self.sidebar_cursor.min((entries.length() - 1).max(0))
  let top = (cursor - list.height + 1).max(0)
  for offset in 0..<list.height {
    let index = top + offset
    guard entries.get(index) is Some(entry) else { break }
    let row = @tui.Rect(
      row=list.row + offset,
      col=list.col,
      width=list.width,
      height=1,
    )
    let focused = index == cursor && self.focus is Sidebar
    match entry {
      SidebarProject(path, count, expanded) => {
        let name = path
          .map(path => {
            path
            .split("/")
            .filter(part => !part.is_empty())
            .last()
            .map(part => part.to_owned())
            .unwrap_or(path)
          })
          .unwrap_or("Chats")
        frame.line(
          row,
          @tui.Line::from_text(
            (if expanded { "⌄ " } else { "› " }) + name + " (\{count})",
            style=if focused { accent() } else { @tui.Style(bold=true) },
          ),
        )
        frame.text(
          row=row.row,
          col=(row.col + row.width - 2).max(row.col),
          "+",
          style=accent(),
        )
      }
      SidebarChat(key) =>
        if self.chats.get(key) is Some(chat) {
          let selected = key == self.active.key && self.pages.page() is None
          let style = if selected {
            @tui.Style(fg=Rgb(190, 221, 255), bg=Rgb(39, 51, 70), bold=true)
          } else {
            muted()
          }
          frame.fill(row, style~)
          let prefix = if self.sidebar_mode is ProjectsMode { "  " } else { "" }
          let status = if chat.run_id is Some(_) {
            "● "
          } else if key.archived {
            "□ "
          } else {
            "  "
          }
          frame.line(
            row,
            @tui.Line::from_text(
              prefix +
              (if focused { "▸" } else { " " }) +
              status +
              chat.title
              .split("\n")
              .next()
              .map(value => value.to_owned())
              .unwrap_or(chat.title),
              style~,
            ),
          )
        }
      SidebarHint(text) =>
        frame.line(row, @tui.Line::from_text(text, style=muted()))
    }
  }
  for
    index, label in [
      " Chats          ^1", " Skills         ^2", " Schedules      ^3", " Settings       ^4",
      " Connected server",
    ] {
    let active = match (index, self.pages.page()) {
      (0, None)
      | (1, Some(@pages.Skills))
      | (2, Some(@pages.Schedules))
      | (3, Some(@pages.Settings)) => true
      _ => false
    }
    frame.line(
      @tui.Rect(
        row=regions.left_nav.row + index,
        col=area.col,
        width=area.width,
        height=1,
      ),
      @tui.Line::from_text(label, style=if active { accent() } else { muted() }),
    )
  }
}
