///|
/// Desktop's spatial hierarchy in terminal cells: conversation rail, chat,
/// editor tabs, right file rail, and the independently toggled bottom sheet.
struct Regions {
  header : @tui.Rect
  left : @tui.Rect
  left_chats : @tui.Rect
  left_nav : @tui.Rect
  main : @tui.Rect
  editor_toggle : @tui.Rect
  tabs : @tui.Rect
  chat : @tui.Rect
  composer : @tui.Rect
  editor : @tui.Rect
  tree : @tui.Rect
  terminal_header : @tui.Rect
  terminal : @tui.Rect
  footer : @tui.Rect
}

///|
fn State::regions(
  self : State,
  size : @tui.Size,
  terminal~ : Bool = self.terminal_visible,
) -> Regions {
  let width = size.width.max(0)
  let height = size.height.max(0)
  let left_width = if self.sidebar_visible && width >= 65 { 23 } else { 0 }
  let main_col = left_width + (if left_width > 0 { 1 } else { 0 })
  let main_width = (width - main_col).max(0)
  let main_height = (height - 2).max(0)
  let sheet_height = if terminal {
    self.terminal_height.min((height - 10).max(1)).max(1)
  } else {
    0
  }
  let sheet_total = if terminal { sheet_height + 1 } else { 0 }
  let body_height = (main_height - sheet_total - 1).max(0)
  let tree_width = if self.right_visible &&
    self.pages.page() is None &&
    width >= 100 {
    21
  } else {
    0
  }
  let middle_width = (main_width -
  tree_width -
  (if tree_width > 0 { 1 } else { 0 })).max(0)
  let editor_width = if self.editor_visible && self.pages.page() is None {
    if width >= 110 {
      middle_width / 2
    } else if self.focus is Workspace {
      middle_width
    } else {
      0
    }
  } else {
    0
  }
  let chat_width = (middle_width -
  editor_width -
  (if editor_width > 0 && middle_width > editor_width { 1 } else { 0 })).max(0)
  let composer_height = if chat_width > 0 {
    (self.active.draft.height(width=(chat_width - 3).max(1), max=5) + 2).min(
      body_height,
    )
  } else {
    0
  }
  let editor_col = main_col +
    chat_width +
    (if chat_width > 0 && editor_width > 0 { 1 } else { 0 })
  let toggle_width = main_width.min(13)
  let rect = fn(row, col, width, height) {
    @tui.Rect(row~, col~, width~, height~)
  }
  {
    header: rect(0, 0, width, height.min(1)),
    left: rect(1, 0, left_width, main_height),
    left_chats: rect(5, 0, left_width, (height - 12).max(0)),
    left_nav: rect((height - 6).max(1), 0, left_width, main_height.min(5)),
    main: rect(1, main_col, main_width, (main_height - sheet_total).max(0)),
    tabs: rect(
      1,
      main_col,
      (main_width - toggle_width).max(0),
      main_height.min(1),
    ),
    editor_toggle: rect(
      1,
      width - toggle_width,
      toggle_width,
      main_height.min(1),
    ),
    chat: rect(2, main_col, chat_width, (body_height - composer_height).max(0)),
    composer: rect(
      2 + body_height - composer_height,
      main_col,
      chat_width,
      composer_height,
    ),
    editor: rect(2, editor_col, editor_width, body_height),
    tree: rect(2, width - tree_width, tree_width, body_height),
    terminal_header: rect(
      (height - sheet_total - 1).max(1),
      main_col,
      main_width,
      if terminal {
        1
      } else {
        0
      },
    ),
    terminal: rect(
      (height - sheet_height - 1).max(1),
      main_col,
      main_width,
      sheet_height,
    ),
    footer: rect((height - 1).max(0), 0, width, height.min(1)),
  }
}

///|
fn contains_point(area : @tui.Rect, row : Int32, col : Int32) -> Bool {
  area.width > 0 &&
  area.height > 0 &&
  row >= area.row &&
  row < area.row + area.height &&
  col >= area.col &&
  col < area.col + area.width
}

///|
async fn State::show_page(
  self : State,
  client : @client.Client,
  page : @pages.Page?,
) -> Unit {
  self.panel_title = None
  if page is Some(page) {
    self.pages.open(client, page, self.context())
    self.focus = Pages
  } else {
    self.pages.close()
    self.focus = Composer
  }
}

///|
async fn State::open_schedule_run(
  self : State,
  client : @client.Client,
  run : @protocol.ScheduleRun,
) -> Unit {
  self.pages.close()
  self.refresh_sessions(client)
  let key : ChatKey = {
    session: run.session,
    workspace: Some(run.workspace),
    archived: false,
  }
  let chat = self.chats
    .get(key)
    .unwrap_or_else(() => {
      let chat = Chat(key, title=run.name)
      self.chats[key] = chat
      self.sidebar.push(key)
      chat
    })
  self.load_chat(client, chat)
}

///|
fn State::editor_shown(self : State) -> Bool {
  self.regions(self.size).editor.width > 0
}

///|
fn State::editor_toggle_mouse(self : State, mouse : @input.MouseEvent) -> Bool {
  guard self.size.width >= 25 &&
    self.size.height >= 7 &&
    mouse.kind is Press(Left) &&
    contains_point(
      self.regions(self.size).editor_toggle,
      mouse.row - 1,
      mouse.col - 1,
    ) else {
    return false
  }
  let shown = self.editor_shown()
  self.pages.close()
  self.panel_title = None
  self.editor_visible = !shown
  if self.editor_visible {
    self.workspace.focus_editor()
    self.focus = Workspace
  } else {
    self.focus = Composer
  }
  true
}
