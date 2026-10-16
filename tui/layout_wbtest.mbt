///|
test "desktop panes keep the bottom terminal below chat and editors" {
  let state = State(Some("/workspace"))
  state.terminal_visible = true
  let size = @tui.Size(width=160, height=45)
  let regions = state.regions(size)
  assert_true(regions.left.width > 0)
  assert_true(regions.chat.width > 0)
  assert_true(regions.editor.width > 0)
  assert_true(regions.tree.width > 0)
  assert_true(regions.left.col + regions.left.width <= regions.chat.col)
  assert_true(regions.chat.col + regions.chat.width <= regions.editor.col)
  assert_true(regions.editor.col + regions.editor.width <= regions.tree.col)
  assert_true(
    regions.composer.row + regions.composer.height <=
    regions.terminal_header.row,
  )
  assert_true(
    regions.editor.row + regions.editor.height <= regions.terminal_header.row,
  )
  assert_eq(regions.terminal.col, regions.main.col)
  assert_eq(regions.terminal.width, regions.main.width)
  assert_eq(regions.terminal.row + regions.terminal.height, regions.footer.row)
}

///|
test "hiding the terminal returns its space to the desktop workbench" {
  let state = State(None)
  let size = @tui.Size(width=140, height=35)
  let hidden = state.regions(size)
  let shown = state.regions(size, terminal=true)
  assert_eq(hidden.terminal.height, 0)
  assert_true(hidden.editor.height > shown.editor.height)
  assert_true(hidden.chat.height > shown.chat.height)
}

///|
test "small terminals keep interactive rectangles within the frame" {
  let state = State(None)
  for width in [40, 64, 80, 100, 110, 160] {
    for height in [10, 20, 40] {
      for terminal in [false, true] {
        let size = @tui.Size(width~, height~)
        let regions = state.regions(size, terminal~)
        for
          area in [
            regions.chat,
            regions.composer,
            regions.editor,
            regions.tree,
            regions.terminal,
          ] {
          assert_true(area.col >= 0 && area.row >= 0)
          assert_true(area.col + area.width <= width)
          assert_true(area.row + area.height <= height)
        }
      }
    }
  }
}
