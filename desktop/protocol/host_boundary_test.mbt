///|
test "host requests omit missing optionals and reject malformed known fields" {
  for input in [Json::empty_object(), { "run_id": null }, { "future": true }] {
    let payload : @protocol.CancelPayload = @json.from_json(input)
    assert_true(payload.run_id is None)
    assert_eq(payload.to_json(), Json::empty_object())
  }
  let payload : @protocol.CancelPayload = @json.from_json({ "run_id": "run-1" })
  assert_eq(payload.to_json(), { "run_id": "run-1" })
  for input in [Json({ "run_id": 42 }), Json::null(), []] {
    let rejected = try {
      let _ : @protocol.CancelPayload = @json.from_json(input)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
