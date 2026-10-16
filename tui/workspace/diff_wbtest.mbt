///|
test "unified diff preserves additions removals and Unicode text" {
  let lines = unified_lines("one\nold 🌙\nthree", "one\nnew 中文\nthree")
  let text = lines.map(line => line.to_text()).join("\n")
  assert_true(text.contains("-old 🌙"))
  assert_true(text.contains("+new 中文"))
  assert_true(text.contains("@@"))
}

///|
test "identical files have an explicit no changes result" {
  assert_eq(
    unified_lines("same\n", "same\n")[0].to_text(),
    "No changes from the task baseline.",
  )
}

///|
test "split diff uses source positions for repeated text and CRLF" {
  for newline in ["\n", "\r\n"] {
    let state = State()
    state.set_demo(diff=true)
    let tab = state.tabs[0]
    tab.original.set_text(["same", "separator", "same"].join(newline))
    tab.editor.set_text(["same", "separator", "changed"].join(newline))
    tab.original.move_to_start()
    tab.editor.move_to_start()
    let frame = @tui.Frame(width=81, height=6)
    tab.draw_diff(frame, frame.area(), false)
    assert_eq(frame.style_at(row=1, col=3).bg, @tui.Style().bg)
    assert_eq(
      frame.style_at(row=3, col=3).bg,
      @tui.Style(bg=Rgb(48, 27, 32)).bg,
    )
    assert_eq(
      frame.style_at(row=3, col=44).bg,
      @tui.Style(bg=Rgb(20, 45, 32)).bg,
    )
  }
}
