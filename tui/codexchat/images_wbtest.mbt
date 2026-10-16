///|
test "Codex images use native app-server image inputs alongside text" {
  assert_eq(inputs("inspect", ["data:image/png;base64,AA=="]), [
    { "type": "text", "text": "inspect" },
    { "type": "image", "url": "data:image/png;base64,AA==" },
  ])
  assert_eq(inputs("", ["data:image/png;base64,AA=="]), [
    { "type": "image", "url": "data:image/png;base64,AA==" },
  ])
}
