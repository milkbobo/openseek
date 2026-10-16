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

///|
test "workspace text has explicit colors on light outer terminals" {
  let state = demo_state()
  let frame = state.view(@tui.Size(width=150, height=40))
  for row in 0..<frame.height() {
    for col in 0..<frame.width() {
      let style = frame.style_at(row~, col~)
      assert_true(
        !(style.bg is Default),
        msg="default background at \{row},\{col}",
      )
      assert_true(
        !(style.fg is Default),
        msg="default foreground at \{row},\{col}",
      )
    }
  }
}

///|
test "transcript layout refreshes replaced content streaming and resized wraps" {
  let chat = Chat({ session: "layout", workspace: None, archived: false, })
  chat.notice("old message")
  let text = fn(width) {
    chat.lines(width).map(line => line.to_text()).join("\n")
  }
  assert_true(text(40).contains("old message"))
  // A reconnect can replace a row with the same count and no sequence.
  chat.rows[0] = {
    ..chat.rows[0],
    text: "新的消息 new message",
    label: "New",
    kind: Assistant,
  }
  assert_true(text(40).contains("New\n新的消息 new message"))
  assert_true(!text(40).contains("old message"))
  chat.goal = Some("finish")
  chat.live_reasoning = "thinking"
  chat.live_answer = "partial"
  chat.pending["steer"] = "steering"
  chat.queued["next"] = "queued"
  let live = text(40)
  for
    expected in ["Goal · finish", "thinking", "partial", "steering", "queued"] {
    assert_true(live.contains(expected))
  }
  let wide_count = chat.lines(40).length()
  assert_true(chat.lines(8).length() > wide_count)
  assert_true(text(8).contains("新的消息\nnew\nmessage"))
  chat.goal = None
  chat.live_reasoning = ""
  chat.live_answer = "finished"
  chat.pending.clear()
  chat.queued.clear()
  let finished = text(40)
  assert_true(finished.contains("finished"))
  for removed in ["finish\n", "thinking", "partial", "steering", "queued"] {
    assert_true(!finished.contains(removed))
  }
  chat.rows.clear()
  assert_true(text(40).contains("What would you like to build?"))
  assert_true(!text(40).contains("new message"))
}
