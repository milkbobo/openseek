///|
test "focus/encode events" {
  assert_eq(@terminal.FocusEvent::Gained.encode(), b"\x1B[I")
  assert_eq(@terminal.FocusEvent::Lost.encode(), b"\x1B[O")
}
