///|
test "scroll redraw with 20 transcript rows" (b : @bench.T) {
  bench_scroll_view(b, 20)
}

///|
test "scroll redraw with 200 transcript rows" (b : @bench.T) {
  bench_scroll_view(b, 200)
}

///|
test "scroll redraw with 1000 transcript rows" (b : @bench.T) {
  bench_scroll_view(b, 1000)
}

///|
fn bench_scroll_view(b : @bench.T, count : Int32) -> Unit {
  let state = State(None)
  let size = @tui.Size(width=180, height=50)
  let paragraph = "修复渲染和滚动。The terminal shares durable conversations with the desktop. Unicode 中文 and long messages must wrap correctly.\n"
  for index in 0..<count {
    state.active.rows.push({
      kind: Assistant,
      label: "SeekMoon",
      text: paragraph.repeat(8),
      sequence: Some(index),
    })
  }
  ignore(state.view(size))
  b.bench(() => {
    state.active.scroll.page_up()
    b.keep(state.view(size))
  })
}
