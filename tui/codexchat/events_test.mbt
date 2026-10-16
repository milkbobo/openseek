///|
fn event(method_ : String, params : Json) -> Json {
  { "method": method_, "params": params, "generation": 0 }
}

///|
fn require_thread(value : @codexchat.Thread?) -> @codexchat.Thread raise {
  value.unwrap_or_error(Failure("Expected a Codex thread update"))
}

///|
test "thread snapshots preserve user, reasoning, assistant and tool messages" {
  let thread = require_thread(
    @codexchat.decode_thread({
      "id": "thread-1",
      "name": "Fix Unicode 🌙",
      "cwd": "/project",
      "projectRoot": "/project",
      "openseekWorktree": { "path": "/project/worktree", "name": "task" },
      "turns": [
        {
          "id": "turn-1",
          "status": "completed",
          "items": [
            {
              "id": "u1",
              "type": "userMessage",
              "content": [{ "type": "text", "text": "Please fix this" }],
            },
            {
              "id": "r1",
              "type": "reasoning",
              "summary": [{ "text": "Checking" }],
            },
            { "id": "a1", "type": "agentMessage", "text": "Fixed 月" },
            {
              "id": "c1",
              "type": "commandExecution",
              "command": "moon test",
              "aggregatedOutput": "Passed",
            },
          ],
        },
      ],
    }),
  )
  assert_eq(thread.title, "Fix Unicode 🌙")
  assert_eq(thread.cwd, Some("/project/worktree"))
  assert_eq(thread.turn_id, None)
  assert_eq(thread.messages.map(message => (message.role, message.text)), [
    ("user", "Please fix this"),
    ("reasoning", "Checking"),
    ("assistant", "Fixed 月"),
    ("tool", "moon test\nPassed"),
  ])
}

///|
test "deltas and completion share one item and late deltas are ignored" {
  let state = @codexchat.State()
  ignore(
    state.apply(
      event("turn/started", {
        "threadId": "t",
        "turn": { "id": "one", "status": "inProgress", "items": [] },
      }),
    ),
  )
  ignore(
    state.apply(
      event("item/agentMessage/delta", {
        "threadId": "t",
        "turnId": "one",
        "itemId": "a",
        "delta": "Hello ",
      }),
    ),
  )
  let thread = require_thread(
    state.apply(
      event("item/agentMessage/delta", {
        "threadId": "t",
        "turnId": "one",
        "itemId": "a",
        "delta": "月",
      }),
    ),
  )
  assert_eq(thread.messages.length(), 1)
  assert_eq(thread.messages[0].text, "Hello 月")
  let thread = require_thread(
    state.apply(
      event("item/completed", {
        "threadId": "t",
        "turnId": "one",
        "item": {
          "id": "a",
          "type": "agentMessage",
          "text": "Canonical answer",
        },
      }),
    ),
  )
  assert_eq(thread.messages.length(), 1)
  assert_eq(thread.messages[0].text, "Canonical answer")
  let thread = require_thread(
    state.apply(
      event("item/agentMessage/delta", {
        "threadId": "t",
        "turnId": "one",
        "itemId": "a",
        "delta": "stale",
      }),
    ),
  )
  assert_eq(thread.messages[0].text, "Canonical answer")
}

///|
test "late predecessor completion preserves the active successor" {
  let state = @codexchat.State()
  ignore(
    state.apply(
      event("turn/started", {
        "threadId": "t",
        "turn": { "id": "second", "status": "inProgress" },
      }),
    ),
  )
  let thread = require_thread(
    state.apply(
      event("turn/completed", {
        "threadId": "t",
        "turn": { "id": "first", "status": "completed" },
      }),
    ),
  )
  assert_eq(thread.turn_id, Some("second"))
  assert_eq(thread.status, "inProgress")
}

///|
test "terminal lifecycle settles an item when completion omitted its items" {
  let state = @codexchat.State()
  ignore(
    state.apply(
      event("turn/started", {
        "threadId": "t",
        "turn": { "id": "one", "status": "inProgress" },
      }),
    ),
  )
  ignore(
    state.apply(
      event("item/reasoning/summaryTextDelta", {
        "threadId": "t",
        "turnId": "one",
        "itemId": "r",
        "delta": "Thinking",
      }),
    ),
  )
  let thread = require_thread(
    state.apply(
      event("turn/completed", {
        "threadId": "t",
        "turn": { "id": "one", "status": "interrupted" },
      }),
    ),
  )
  assert_eq(thread.turn_id, None)
  assert_eq(thread.status, "interrupted")
  assert_true(thread.messages[0].complete)
}

///|
test "tool output retains its command and raw chunk boundaries" {
  let state = @codexchat.State()
  ignore(
    state.apply(
      event("item/started", {
        "threadId": "t",
        "turnId": "one",
        "item": { "id": "c", "type": "commandExecution", "command": "echo hi" },
      }),
    ),
  )
  ignore(
    state.apply(
      event("item/commandExecution/outputDelta", {
        "threadId": "t",
        "turnId": "one",
        "itemId": "c",
        "delta": "he",
      }),
    ),
  )
  let thread = require_thread(
    state.apply(
      event("item/commandExecution/outputDelta", {
        "threadId": "t",
        "turnId": "one",
        "itemId": "c",
        "delta": "llo",
      }),
    ),
  )
  assert_eq(thread.messages[0].text, "echo hi\nhello")
}

///|
test "request generations prevent stale snapshots resurrecting resolved questions" {
  let state = @codexchat.State()
  assert_true(
    state.apply_request({
      "response_token": "token",
      "request_id": 7,
      "method": "item/commandExecution/requestApproval",
      "params": { "threadId": "t", "command": "run" },
      "generation": 3,
    }),
  )
  assert_eq(state.requests().length(), 1)
  ignore(
    state.apply({
      "method": "serverRequest/resolved",
      "params": { "requestId": 7 },
      "generation": 4,
    }),
  )
  state.apply_request_snapshot({
    data: [
      {
        "response_token": "token",
        "request_id": 7,
        "method": "item/commandExecution/requestApproval",
        "params": { "threadId": "t" },
      },
    ],
    generation: 3,
  })
  assert_eq(state.requests().length(), 0)
}

///|
test "approval results follow each reverse request contract" {
  let state = @codexchat.State()
  assert_true(
    state.apply_request({
      "response_token": "permissions",
      "request_id": "p",
      "method": "item/permissions/requestApproval",
      "params": {
        "threadId": "t",
        "permissions": { "network": { "enabled": true } },
      },
      "generation": 1,
    }),
  )
  let request = state.requests()[0]
  assert_eq(
    request.approval_result(true),
    Some({ "permissions": { "network": { "enabled": true } }, "scope": "turn" }),
  )
  assert_eq(
    request.approval_result(false),
    Some({ "permissions": {}, "scope": "turn" }),
  )
}

///|
test "user-input answers require every question and retain question identities" {
  let state = @codexchat.State()
  assert_true(
    state.apply_request({
      "response_token": "questions",
      "request_id": 8,
      "method": "item/tool/requestUserInput",
      "params": {
        "threadId": "t",
        "questions": [{ "id": "choice" }, { "id": "detail" }],
      },
      "generation": 1,
    }),
  )
  let request = state.requests()[0]
  assert_eq(request.approval_result(true), None)
  assert_eq(request.answer_result({ "choice": "A", "detail": "Use 月" }), {
    "answers": {
      "choice": { "answers": ["A"] },
      "detail": { "answers": ["Use 月"] },
    },
  })
  try request.answer_result({ "choice": "A" }) catch {
    @codexchat.CodexError(message) =>
      assert_true(message.contains("Every question"))
  } noraise {
    _ => fail("Expected missing answer error")
  }
}
