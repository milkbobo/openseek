///|
async fn State::key(
  self : State,
  client : @client.Client,
  key : @input.KeyEvent,
) -> Bool {
  if key.kind is Release {
    if self.terminal_visible &&
      self.focus is Terminal &&
      self.terminals.get(self.terminal_index) is Some(tab) {
      terminal_write(client, tab, tab.screen.key(key))
    }
    return false
  }
  if key.modifiers.ctrl() && key.code is Char('t') {
    if self.terminal_visible {
      self.terminal_focus(client, false)
      self.terminal_visible = false
      self.focus = if self.pages.page() is Some(_) { Pages } else { Composer }
    } else {
      self.open_terminal(client, None)
    }
    return false
  }
  if key.modifiers.ctrl() && key.modifiers.alt() && key.code is (Up | Down) {
    self.terminal_height = (self.terminal_height +
    (if key.code is Up { 2 } else { -2 })).max(3)
    if self.terminal_visible {
      self.resize_terminals(client)
    }
    return false
  }
  if key.code is F6 {
    self.terminal_focus(client, false)
    let regions = self.regions(self.size)
    let panes : Array[Focus] = [
      if self.pages.page() is Some(_) {
        Pages
      } else {
        Composer
      },
    ]
    if self.pages.page() is None &&
      (self.editor_visible || regions.tree.width > 0) {
      panes.push(Workspace)
    }
    if self.terminal_visible {
      panes.push(Terminal)
    }
    if regions.left.width > 0 {
      panes.push(Sidebar)
    }
    let current = panes.search(self.focus).unwrap_or(0)
    let delta = if key.modifiers.shift() { -1 } else { 1 }
    self.focus = panes[(current + delta + panes.length()) % panes.length()]
    if self.focus is Workspace {
      if self.editor_visible {
        self.workspace.focus_editor()
      } else {
        self.workspace.focus_tree()
      }
    }
    if self.focus is Terminal {
      self.terminal_focus(client, true)
    }
    return false
  }
  if key.modifiers.ctrl() {
    match key.code {
      Char('1') => {
        self.terminal_focus(client, false)
        self.show_page(client, None)
        return false
      }
      Char('2') => {
        self.terminal_focus(client, false)
        self.show_page(client, Some(@pages.Skills))
        return false
      }
      Char('3') => {
        self.terminal_focus(client, false)
        self.show_page(client, Some(@pages.Schedules))
        return false
      }
      Char('4') => {
        self.terminal_focus(client, false)
        self.show_page(client, Some(@pages.Settings))
        return false
      }
      Char('e') => {
        self.terminal_focus(client, false)
        let workspace_focused = self.focus is Workspace
        self.show_page(client, None)
        if self.editor_visible && workspace_focused {
          self.editor_visible = false
          self.focus = Composer
        } else {
          self.editor_visible = true
          self.workspace.focus_editor()
          self.focus = Workspace
        }
        self.resize_terminals(client)
        return false
      }
      Char('r') => {
        self.terminal_focus(client, false)
        self.show_page(client, None)
        self.right_visible = !self.right_visible
        if self.right_visible {
          self.workspace.browse(client, self.context())
          self.workspace.focus_tree()
          self.focus = Workspace
        } else {
          self.focus = Composer
        }
        return false
      }
      _ => ()
    }
  }
  if self.terminal_visible &&
    self.focus is Terminal &&
    self.terminals.get(self.terminal_index) is Some(tab) {
    if key.modifiers.alt() && key.code is Char('w') {
      self.close_terminal(client)
    } else if key.modifiers.ctrl() && key.code is (Left | Right) {
      self.terminal_focus(client, false)
      let delta = if key.code is Left { -1 } else { 1 }
      self.terminal_index = (
          self.terminal_index + delta + self.terminals.length()
        ) %
        self.terminals.length()
      self.terminal_focus(client, true)
    } else if key.modifiers.shift() && key.code is (PageUp | PageDown) {
      tab.screen.scroll(if key.code is PageUp { -tab.rows } else { tab.rows })
    } else {
      tab.screen.scroll_to_bottom()
      terminal_write(client, tab, tab.screen.key(key))
    }
    return false
  }
  if key.modifiers.ctrl() {
    match key.code {
      Char('n') => {
        self.execute(client, "/new")
        return false
      }
      Char('b') => {
        self.sidebar_visible = !self.sidebar_visible
        self.focus = if self.sidebar_visible { Sidebar } else { Composer }
        return false
      }
      Char('p') => {
        self.show_page(client, None)
        self.panel("Commands", local_help())
        self.active.draft.set_text("/")
        self.focus = Composer
        return false
      }
      Char('c') => {
        self.startup_submission = None
        if self.active.run_id is Some(_) {
          self.execute(client, "/stop")
        } else {
          self.active.draft.clear()
        }
        return false
      }
      _ => ()
    }
  }
  if self.pages.page() is Some(_) && self.focus is Pages {
    ignore(self.pages.key(client, key, self.context()))
    if self.pages.take_open_run() is Some(run) {
      self.open_schedule_run(client, run)
    }
    if self.pages.page() is None {
      self.focus = Composer
    }
    return false
  }
  if self.focus is Workspace {
    if !self.workspace.key(client, key) && key.code is Escape {
      self.focus = Composer
    }
    return false
  }
  if self.sidebar_key(client, key) {
    return false
  }
  match key.code {
    Escape => {
      if self.pages.page() is Some(_) {
        self.show_page(client, None)
      } else {
        self.panel_title = None
        self.focus = Composer
      }
      false
    }
    F1 => {
      self.panel("Commands", local_help())
      false
    }
    PageUp => {
      if self.panel_title is Some(_) {
        self.panel_scroll.page_up()
      } else {
        self.active.scroll.page_up()
      }
      false
    }
    PageDown => {
      if self.panel_title is Some(_) {
        self.panel_scroll.page_down()
      } else {
        self.active.scroll.page_down()
      }
      false
    }
    Tab if self.focus is Composer &&
      self.active.prediction_text() is Some(prediction) => {
      self.active.draft.set_text(prediction)
      false
    }
    Tab => {
      self.focus = if self.focus is Sidebar {
        if self.pages.page() is Some(_) {
          Pages
        } else {
          Composer
        }
      } else {
        Sidebar
      }
      false
    }
    _ => {
      if self.focus is Sidebar {
        if self.pages.page() is Some(_) {
          self.focus = Pages
          ignore(self.pages.key(client, key, self.context()))
          return false
        }
        self.focus = Composer
      }
      !self.active.draft.key(key) && key.code is Enter
    }
  }
}

///|
async fn State::mouse(
  self : State,
  client : @client.Client,
  term : @tui.Terminal?,
  mouse : @input.MouseEvent,
) -> Unit {
  let regions = self.regions(self.size)
  // tty reports one-based cells; layout and Screen use zero-based cells.
  let row = mouse.row - 1
  let col = mouse.col - 1
  if mouse.kind is Press(Left) &&
    regions.left.width > 0 &&
    row == regions.left.row &&
    contains_point(regions.left, row, col) {
    self.terminal_focus(client, false)
    self.execute(client, "/new")
    return
  }
  if self.terminal_visible &&
    contains_point(regions.terminal_header, row, col) &&
    mouse.kind is Press(Left) {
    self.focus = Terminal
    self.terminal_focus(client, true)
    return
  }
  if self.terminal_visible &&
    self.terminals.get(self.terminal_index) is Some(tab) {
    let area = regions.terminal
    if contains_point(area, row, col) {
      if mouse.kind is Press(_) && self.focus != Terminal {
        self.focus = Terminal
        self.terminal_focus(client, true)
      }
      let relative_mouse = @input.MouseEvent::new(
        mouse.kind,
        row - area.row,
        col - area.col,
        modifiers=mouse.modifiers,
      )
      terminal_write(client, tab, tab.screen.mouse(relative_mouse))
      return
    }
  }
  if contains_point(regions.left_nav, row, col) && mouse.kind is Press(Left) {
    self.terminal_focus(client, false)
    match row - regions.left_nav.row {
      0 => self.show_page(client, None)
      1 => self.show_page(client, Some(@pages.Skills))
      2 => self.show_page(client, Some(@pages.Schedules))
      3 => self.show_page(client, Some(@pages.Settings))
      _ => {
        self.show_page(client, None)
        self.panel("Connection", [self.server_url])
      }
    }
    return
  }
  if self.sidebar_mouse(client, mouse, regions) {
    self.terminal_focus(client, false)
    return
  }
  if self.pages.page() is Some(_) &&
    contains_point(regions.main, row, col) &&
    self.pages.mouse(client, mouse, self.context()) {
    self.terminal_focus(client, false)
    self.focus = Pages
    if self.pages.take_open_run() is Some(run) {
      self.open_schedule_run(client, run)
    }
    return
  }
  if self.pages.page() is None &&
    (
      contains_point(regions.editor, row, col) ||
      contains_point(regions.tree, row, col)
    ) &&
    self.workspace.mouse(client, mouse, self.context()) {
    self.terminal_focus(client, false)
    self.focus = Workspace
    return
  }
  if mouse.kind is Press(_) &&
    self.pages.page() is None &&
    (
      contains_point(regions.composer, row, col) ||
      contains_point(regions.chat, row, col)
    ) {
    self.terminal_focus(client, false)
    self.focus = Composer
  }
  if self.pages.page() is Some(_) ||
    !(contains_point(regions.chat, row, col) ||
    contains_point(regions.composer, row, col)) {
    return
  }
  if mouse.kind is Scroll(direction) {
    let delta = match direction {
      Up => -3
      Down => 3
      Left | Right => return
    }
    if self.panel_title is Some(_) {
      self.panel_scroll.scroll_by(delta)
    } else {
      self.active.scroll.scroll_by(delta)
    }
  } else {
    let selection = if self.panel_title is Some(_) {
      self.panel_selection
    } else {
      self.active.selection
    }
    selection.mouse(mouse)
    if mouse.kind is Release(Left) &&
      selection.text() is Some(text) &&
      term is Some(term) {
      term.set_clipboard(text)
    }
    ignore(self.active.draft.mouse(mouse))
  }
}
