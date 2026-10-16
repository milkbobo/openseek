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
