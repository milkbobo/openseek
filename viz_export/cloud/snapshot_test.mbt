///|
test "snapshot preserves visible tool messages and embeds the downloadable dataset" {
  let input : Json = {
    "session_id": "session-example",
    "title": "Example <script>",
    "shell_html": "<html><script src=\"/viz_app.js\"></script></html>",
    "bundle_js": "/* </SCRIPT> */",
    "messages": [
      {
        "kind": "tool_call",
        "data": {
          "id": "call-1",
          "function": { "name": "mbtx", "arguments": "{}" },
        },
        "created_at": 100,
        "task_id": "ignored",
      },
      {
        "kind": "tool_result",
        "data": {
          "tool_call_id": "call-1",
          "content": "<result>",
          "is_error": true,
        },
        "created_at": 101,
      },
    ],
  }
  guard @cloud.render(input)
    is { "html": String(html), "json": String(json), .. } else {
    fail("expected standalone files")
  }
  assert_true(html.contains("window.__OPENSEEK_DATA__"))
  assert_true(html.contains("<\\/SCRIPT>"))
  assert_false(html.contains("<result>"))
  guard @json.parse(json) is { "/api/sessions/session-0": String(record), .. } &&
    @json.parse(record) is { "found": true, "events": String(events), .. } else {
    fail("expected visible session records")
  }
  let lines = events.split("\n").filter(line => !line.is_empty()).collect()
  assert_eq(@json.parse(lines[0]), {
    "sequence": 1,
    "ts": 100,
    "item": {
      "kind": "assistant",
      "payload": {
        "content": "",
        "tool_calls": [{ "id": "call-1", "name": "mbtx", "arguments": "{}" }],
      },
    },
  })
  assert_eq(@json.parse(lines[1]), {
    "sequence": 2,
    "ts": 101,
    "item": {
      "kind": "tool_result",
      "payload": {
        "tool_call_id": "call-1",
        "content": "<result>",
        "is_error": true,
      },
    },
  })
}

///|
test "snapshot rejects missing input and malformed messages instead of exporting empty history" {
  for
    input in [
      Json::null(),
      { "session_id": "id", "title": "Title", "messages": [] },
    ] {
    let result = try @cloud.render(input) catch {
      error => Err(error)
    } noraise {
      value => Ok(value)
    }
    assert_true(result is Err(_))
  }
  let malformed : Json = {
    "session_id": "id",
    "title": "Title",
    "shell_html": "",
    "bundle_js": "",
    "messages": [{ "kind": "user", "data": { "content": "Hello" } }],
  }
  let result = try @cloud.render(malformed) catch {
    error => Err(error)
  } noraise {
    value => Ok(value)
  }
  assert_true(result is Err(@cloud.InvalidHistory(_)))
}

///|
test "ordinary Cloud assistant messages decode through the visualizer log parser" {
  let events = @cloud.envelope(
      1,
      "assistant_message",
      { "content": "Visible answer" },
      100,
    ).stringify() +
    "\n"
  let parsed = @session_log.parse_events(events)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.events.length(), 1)
}
