///|
test "minimal calls keep full details out of collapsed headers" {
  let call = @toolcall.Call(
    "a",
    "mbtx",
    arguments="{\"description\":\"Check 中文\\nfiles\",\"source\":\"SECRET_SCRIPT\"}",
  )
  assert_eq(call.lines(80).length(), 1)
  assert_eq(call.lines(80)[0].to_text(), "▸ … mbtx · Check 中文 files")
  let done = call.finish("SECRET_OUTPUT", brief="exit 0", status=Succeeded)
  assert_eq(done.lines(80)[0].to_text(), "▸ ✓ mbtx · Check 中文 files")
  let expanded = done
    .lines(80, expanded=true)
    .map(line => line.to_text())
    .join("\n")
  assert_true(expanded.contains("SECRET_SCRIPT"))
  assert_true(expanded.contains("SECRET_OUTPUT"))
  for width in [1, 2, 8, 17, 40] {
    assert_eq(done.lines(width).length(), 1)
    assert_true(done.lines(width)[0].width() <= width)
  }
  let failed = call.finish(
    "permission denied",
    brief="Cannot read file",
    status=Failed,
  )
  assert_true(failed.lines(80)[0].to_text().contains("✗"))
  assert_true(
    call
    .interrupt()
    .lines(80, expanded=true)
    .map(line => line.to_text())
    .join("\n")
    .contains("No result recorded"),
  )
}

///|
test "caption fallback preserves malformed and large arguments only in details" {
  for arguments in ["not json", "x".repeat(70000)] {
    let call = @toolcall.Call("a", "read", arguments~)
    assert_eq(call.lines(40)[0].to_text(), "▸ … read")
    assert_eq(call.arguments, Some(arguments))
  }
  let call = @toolcall.Call(
    "a",
    "shell",
    arguments="{\"description\":\"Run checks\"}",
  )
  assert_eq(
    call.finish("output", brief="RAW COMMAND", status=Succeeded).lines(80)[0].to_text(),
    "▸ ✓ shell · Run checks",
  )
  assert_eq(
    @toolcall.Call("a", "read")
    .finish("body", brief="README.md", status=Succeeded)
    .lines(80)[0].to_text(),
    "▸ ✓ read · README.md",
  )
}
