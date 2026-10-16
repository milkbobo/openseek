///|
test "a new server epoch accepts lower reverse request generations" {
  let state = State()
  state.apply_request_snapshot({ generation: 40, data: [], })
  assert_eq(state.request_generation, 40)
  state.begin_connection()
  state.apply_request_snapshot({ generation: 0, data: [], })
  assert_eq(state.request_generation, 0)
}
