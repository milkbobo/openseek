///|
test "editor save codecs preserve expected absence and empty content" {
  let create : @protocol.WriteFilePayload = {
    session: "s",
    root: Some("/workspace"),
    path: "new.txt",
    content: "",
    expected_content: None,
  }
  assert_eq(@json.from_json(create.to_json()), create)
  assert_true(create.to_json() is { "expected_content": Null, .. })
  let update : @protocol.WriteFilePayload = {
    ..create,
    expected_content: Some(""),
  }
  assert_eq(@json.from_json(update.to_json()), update)
  assert_true(update.to_json() is { "expected_content": String(""), .. })
  let reply : @protocol.WriteFileReply = { path: "/workspace/new.txt", }
  assert_eq(@json.from_json(reply.to_json()), reply)
}

///|
test "editor save rejects malformed expected content and missing content" {
  for
    json in [
      (
        {
          "session": "s",
          "root": "/workspace",
          "path": "new.txt",
          "content": "",
          "expected_content": 42,
        } : Json),
      ({ "session": "s", "path": "/workspace/new.txt" } : Json),
    ] {
    try {
      let decoded : @protocol.WriteFilePayload = @json.from_json(json)
      ignore(decoded)
    } catch {
      JsonDecodeError(_) => ()
    } noraise {
      _ => fail("malformed editor save was accepted")
    }
  }
}
