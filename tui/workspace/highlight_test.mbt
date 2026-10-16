///|
test "MoonBit file editor colors keywords and retains source text" {
  let state = @workspace.State()
  state.set_demo()
  let frame = @tui.Frame(width=100, height=20)
  state.draw_editor(frame, frame.area(), focused=true)
  assert_true(
    frame.to_text().contains("fn greeting(name : String) -> String {"),
  )
  // Two-digit line numbers occupy four columns; the keyword begins there.
  assert_true(frame.style_at(row=2, col=4).fg is Rgb(86, 156, 214))
}

///|
test "MoonBit highlighting survives editing wrapping and split diff backgrounds" {
  let state = @workspace.State()
  state.set_demo()
  state.focus_editor()
  assert_true(state.paste("let 中文 = \"🌙\"\n"))
  let frame = @tui.Frame(width=100, height=20)
  state.draw_editor(frame, frame.area(), focused=true)
  assert_true(frame.style_at(row=1, col=4).fg is Rgb(86, 156, 214))
  assert_true(frame.style_at(row=1, col=16).fg is Rgb(206, 145, 120))
  let narrow = @tui.Frame(width=20, height=20)
  state.draw_editor(narrow, narrow.area())
  assert_true(narrow.style_at(row=1, col=4).fg is Rgb(86, 156, 214))
  state.set_demo(diff=true)
  let diff = @tui.Frame(width=121, height=16)
  state.draw_editor(diff, diff.area())
  assert_true(diff.style_at(row=3, col=4).fg is Rgb(86, 156, 214))
  assert_true(diff.style_at(row=3, col=65).fg is Rgb(86, 156, 214))
  assert_true(diff.style_at(row=4, col=6).fg is Rgb(206, 145, 120))
  assert_true(diff.style_at(row=4, col=6).bg is Rgb(48, 27, 32))
  assert_true(diff.style_at(row=4, col=67).fg is Rgb(206, 145, 120))
  assert_true(diff.style_at(row=4, col=67).bg is Rgb(20, 45, 32))
  let narrow_diff = @tui.Frame(width=40, height=16)
  state.draw_editor(narrow_diff, narrow_diff.area())
  assert_true(narrow_diff.style_at(row=2, col=4).fg is Rgb(86, 156, 214))
}
