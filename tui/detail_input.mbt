///|
fn Chat::toggle_detail(self : Chat, id : DetailId) -> Unit {
  if self.expanded_details.contains(id) {
    self.expanded_details.remove(id)
  } else {
    self.expanded_details.add(id)
  }
  self.selected_detail = Some(id)
  self.selection.clear()
  self.scroll.hold()
}

///|
fn Chat::detail_at(self : Chat, row : Int32) -> DetailId? {
  self.layout.bind(layout => {
    layout.detail_headers
    .iter()
    .find_first(pair => pair.1 == row)
    .map(pair => pair.0)
  })
}

///|
fn Chat::select_detail(self : Chat, direction : Int32, height : Int32) -> Unit {
  guard self.layout is Some(layout) && !layout.detail_headers.is_empty() else {
    return
  }
  let headers = layout.detail_headers
  let mut current : Int32? = None
  let mut visible : Int32? = None
  for index, (id, row) in headers {
    if Some(id) == self.selected_detail {
      current = Some(index)
    }
    if visible is None && row >= self.scroll.offset() {
      visible = Some(index)
    }
  }
  let index = if current is Some(index) {
    (index + direction).clamp(min=0, max=headers.length() - 1)
  } else {
    visible.unwrap_or(headers.length() - 1)
  }
  let (id, row) = headers[index]
  self.selected_detail = Some(id)
  if row < self.scroll.offset() {
    self.scroll.scroll_by(row - self.scroll.offset())
  } else if row >= self.scroll.offset() + height {
    self.scroll.scroll_by(row - self.scroll.offset() - height + 1)
  }
}

///|
// Shared by the connected client and offline demo. Only a click (not a text
// selection drag) on the header toggles it; detail text remains copyable.
fn State::detail_mouse(self : State, mouse : @input.MouseEvent) -> Bool {
  let area = self.regions(self.size).chat
  let row = mouse.row - 1
  let col = mouse.col - 1
  if self.panel_title is Some(_) || self.pages.page() is Some(_) {
    return false
  }
  match mouse.kind {
    Press(Left) if contains_point(area, row, col) => {
      let id = self.active.detail_at(
        row - area.row + self.active.scroll.offset(),
      )
      self.active.pressed_detail = id.map(id => (id, row, col))
    }
    Release(Left) => {
      let pressed = self.active.pressed_detail
      self.active.pressed_detail = None
      if pressed is Some((id, start_row, start_col)) &&
        row == start_row &&
        col == start_col &&
        contains_point(area, row, col) &&
        self.active.detail_at(row - area.row + self.active.scroll.offset()) ==
        Some(id) {
        self.active.toggle_detail(id)
        self.focus = Transcript
        return true
      }
    }
    Move | Drag(_) | Scroll(_) => self.active.pressed_detail = None
    _ => ()
  }
  false
}

///|
fn State::detail_key(self : State, key : @input.KeyEvent) -> Bool {
  guard self.focus is Transcript else { return false }
  if key.kind is Release {
    return true
  }
  match key.code {
    Enter | Char(' ') =>
      if self.active.selected_detail is Some(id) {
        self.active.toggle_detail(id)
      }
    Up | Down =>
      self.active.select_detail(
        if key.code is Up {
          -1
        } else {
          1
        },
        self.regions(self.size).chat.height,
      )
    PageUp => self.active.scroll.page_up()
    PageDown => self.active.scroll.page_down()
    Escape => {
      self.active.selected_detail = None
      self.focus = Composer
    }
    _ => ()
  }
  true
}
