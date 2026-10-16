///|
fn test_chat(root : String) -> Chat {
  let chat = Chat({
    session: "same-id",
    workspace: Some(root),
    archived: false,
  })
  chat.session_root = Some(root + "/.openseek")
  chat
}

///|
fn user_event(sequence : Int32, text : String) -> @protocol.SessionEvent {
  {
    sequence,
    ts: None,
    item: User({
      content: @agent_protocol.Content([Text(text)]),
      submission_id: None,
    }),
  }
}

///|
fn commit(
  root : String,
  sequence : Int32,
  text : String,
) -> @protocol.SessionCommitPayload {
  {
    session: "same-id",
    session_root: root + "/.openseek",
    sequence,
    event: user_event(sequence, text),
  }
}

///|
test "durable commits route by store as well as session id" {
  let state = State(None)
  let one = test_chat("/one")
  let two = test_chat("/two")
  state.chats[one.key] = one
  state.chats[two.key] = two
  state.notification(SessionEvent(commit("/two", 1, "Only two")))
  assert_eq(one.rows.length(), 0)
  assert_eq(two.rows.length(), 1)
  assert_eq(two.rows[0].text, "Only two")
  assert_true(state.unique_session("same-id") is None)
}

///|
test "load reconciles buffered commits against authoritative watermark" {
  let chat = test_chat("/one")
  chat.loading = true
  chat.commit(commit("/one", 1, "snapshot duplicate"))
  chat.commit(commit("/one", 3, "later"))
  chat.commit(commit("/one", 2, "snapshot duplicate"))
  chat.snapshot({
    session: {
      version: Some(1),
      id: Some("same-id"),
      system_prompt: None,
      events: Some([user_event(1, "first"), user_event(2, "second")]),
    },
    watermark: Some(2),
    prediction: None,
  })
  assert_eq(chat.watermark, 3)
  assert_eq(chat.rows.map(row => row.text), ["first", "second", "later"])
  chat.commit(commit("/one", 3, "duplicate"))
  assert_eq(chat.rows.length(), 3)
}

///|
test "stream retry clears only live previews and keeps durable rows" {
  let chat = test_chat("/one")
  chat.commit(commit("/one", 1, "prompt"))
  chat.stream(AssistantDelta(content="discard this partial answer"))
  chat.stream(ReasoningDelta(content="discard this partial reasoning"))
  chat.stream(StreamRetry(attempt=2, max_attempts=5, reason="offline"))
  assert_eq(chat.live_answer, "")
  assert_eq(chat.live_reasoning, "")
  assert_eq(chat.rows[0].text, "prompt")
  assert_true(chat.status.contains("2/5"))
}

///|
test "canonical assistant commit settles live preview without duplication" {
  let chat = test_chat("/one")
  chat.stream(AssistantDelta(content="partial"))
  chat.append_item({
    sequence: 1,
    ts: None,
    item: Assistant({
      content: "complete",
      reasoning_content: Some("reason"),
      tool_calls: None,
      is_replay: None,
    }),
  })
  assert_eq(chat.live_answer, "")
  assert_eq(chat.live_reasoning, "")
  assert_eq(chat.rows.map(row => row.text), ["reason", "complete"])
  let calls : @protocol.SessionEvent = {
    sequence: 2,
    ts: None,
    item: Assistant({
      content: "",
      reasoning_content: None,
      is_replay: None,
      tool_calls: Some([
        {
          id: "one",
          name: "read",
          arguments: "{\"description\":\"First file\"}",
        },
        {
          id: "two",
          name: "read",
          arguments: "{\"description\":\"Second file\"}",
        },
      ]),
    }),
  }
  let result : @protocol.SessionEvent = {
    sequence: 3,
    ts: None,
    item: ToolResult({
      tool_call_id: "two",
      tool_name: "read",
      content: @agent_protocol.Content([Text("SECOND OUTPUT")]),
      is_error: true,
      brief: Some("Failed second"),
      data: None,
    }),
  }
  chat.append_item(calls)
  chat.append_item(result)
  assert_eq(chat.rows.length(), 4)
  assert_true(chat.rows[2].kind is Tool({ id: "one", status: Pending, .. }))
  assert_true(chat.rows[3].kind is Tool({ id: "two", status: Failed, .. }))
  let collapsed = chat.lines(80).map(line => line.to_text()).join("\n")
  assert_true(!collapsed.contains("SECOND OUTPUT"))
  chat.toggle_detail(ToolDetail("two"))
  assert_true(
    chat
    .lines(80)
    .map(line => line.to_text())
    .join("\n")
    .contains("SECOND OUTPUT"),
  )
  chat.snapshot({
    session: {
      version: Some(1),
      id: Some("same-id"),
      system_prompt: None,
      events: Some([calls, result]),
    },
    watermark: Some(3),
    prediction: None,
  })
  assert_eq(chat.rows.length(), 2)
  assert_true(
    chat
    .lines(80)
    .map(line => line.to_text())
    .join("\n")
    .contains("SECOND OUTPUT"),
  )
  chat.append_item({
    sequence: 4,
    ts: None,
    item: Terminal(Interrupted("Stopped")),
  })
  assert_true(chat.rows[0].kind is Tool({ status: Interrupted, .. }))
  // Result-only history remains inspectable when the call is absent.
  let orphan = test_chat("/orphan")
  orphan.append_item(result)
  orphan.toggle_detail(ToolDetail("two"))
  assert_true(
    orphan
    .lines(80)
    .map(line => line.to_text())
    .join("\n")
    .contains("SECOND OUTPUT"),
  )
}

///|
test "switching conversations keeps independent drafts and active streams" {
  let state = State(Some("/one"))
  let first = state.active
  first.draft.insert("draft one")
  first.run_id = Some("running-one")
  state.new_chat(Some("/two"))
  state.active.draft.insert("draft two")
  state.notification(
    AgentEvent({
      session: first.key.session,
      run_id: Some("running-one"),
      event: AssistantDelta(content="background progress"),
    }),
  )
  assert_eq(first.draft.text(), "draft one")
  assert_eq(first.live_answer, "background progress")
  assert_eq(state.active.draft.text(), "draft two")
  assert_eq(state.active.live_answer, "")
}

///|
test "approval snapshots reject an older generation" {
  let state = State(None)
  state.approval_generation = 5
  state.notification(AgentApprovals({ generation: 4, approvals: [], }))
  assert_eq(state.approval_generation, 5)
}

///|
test "dropped steering restores text for resubmission" {
  let chat = test_chat("/one")
  chat.draft.set_text("follow-up")
  chat.remember_steer("submission-1", "run-1", "follow-up")
  chat.pending["submission-1"] = "follow-up"
  chat.stream(
    SteerDropped(
      content=@agent_protocol.Content([Text("follow-up")]),
      submission_id=Some("submission-1"),
    ),
    run_id=Some("run-1"),
  )
  assert_eq(chat.draft.text(), "follow-up")
  assert_eq(chat.pending.length(), 0)
  assert_true(chat.rows[0].text.contains("Resubmit"))
}

///|
test "view supports narrow layouts and Unicode without exposing controls" {
  let state = State(Some("/项目"))
  state.active.notice("你好 🌙\u001b[2J")
  for
    size in [
      @tui.Size(width=12, height=4),
      @tui.Size(width=50, height=15),
      @tui.Size(width=100, height=30),
    ] {
    let frame = state.view(size)
    assert_eq(frame.width(), size.width)
    assert_eq(frame.height(), size.height)
    assert_true(!frame.to_text().contains("\u001b"))
  }
}

///|
test "durable terminal records render final and context-yield answers" {
  let chat = test_chat("/one")
  for
    terminal in [
      @protocol.Finished("final answer"),
      @protocol.ContextYield("continue here"),
    ] {
    chat.append_item({ sequence: 1, ts: None, item: Terminal(terminal), })
  }
  assert_eq(
    chat.rows.filter(row => row.kind == Assistant).map(row => row.text),
    ["final answer", "continue here"],
  )
}

///|
test "snapshot keeps an unresolved sequence gap for the next reload" {
  let chat = test_chat("/one")
  chat.loading = true
  chat.commit(commit("/one", 4, "fourth"))
  chat.snapshot({
    session: {
      version: Some(1),
      id: Some("same-id"),
      system_prompt: None,
      events: Some([user_event(1, "first")]),
    },
    watermark: Some(1),
    prediction: None,
  })
  assert_true(chat.needs_reload)
  assert_eq(chat.watermark, 1)
  assert_eq(chat.rows.map(row => row.text), ["first"])
  assert_eq(chat.buffered.length(), 1)
  chat.snapshot({
    session: {
      version: Some(1),
      id: Some("same-id"),
      system_prompt: None,
      events: Some([
        user_event(1, "first"),
        user_event(2, "second"),
        user_event(3, "third"),
      ]),
    },
    watermark: Some(3),
    prediction: None,
  })
  assert_true(!chat.needs_reload)
  assert_eq(chat.watermark, 4)
  assert_eq(chat.rows.map(row => row.text), [
    "first", "second", "third", "fourth",
  ])
}

///|
test "late run snapshots cannot resurrect a finished live run" {
  let state = State(Some("/one"))
  let chat = state.active
  chat.run_id = Some("r1")
  let owners = [(chat, chat.lifecycle_generation)]
  state.notification(
    AgentFinished({
      run_id: "r1",
      status: "finished",
      answer: None,
      exit_code: None,
    }),
  )
  state.reconcile_runs(
    {
      approval_generation: 0,
      approvals: [],
      settled: [],
      runs: [
        {
          run_id: "r1",
          submission_id: None,
          engine: None,
          model: None,
          max_steps: None,
          session: chat.key.session,
          session_root: None,
        },
      ],
    },
    owners,
  )
  assert_true(chat.run_id is None)
  assert_eq(chat.status, "finished")
}

///|
test "run settlement reconciles its pending submission and preserves another store" {
  let state = State(None)
  let one = test_chat("/one")
  let two = test_chat("/two")
  one.run_id = Some("r1")
  two.run_id = Some("r2")
  one.pending["submission-one"] = "one"
  two.pending["submission-two"] = "two"
  state.reconcile_runs(
    {
      approval_generation: 0,
      approvals: [],
      runs: [
        {
          run_id: "r2",
          submission_id: Some("submission-two"),
          engine: None,
          model: None,
          max_steps: None,
          session: "same-id",
          session_root: two.session_root,
        },
      ],
      settled: [
        {
          run_id: "r1",
          session: "same-id",
          submission_id: Some("submission-one"),
          status: "finished",
          exit_code: Some(0),
        },
      ],
    },
    [(one, 0), (two, 0)],
  )
  assert_eq(one.status, "finished")
  assert_true(one.pending.is_empty())
  assert_eq(two.run_id, Some("r2"))
  assert_true(two.pending.contains("submission-two"))
}

///|
test "queued promotion is replaced by the durable user receipt" {
  let state = State(Some("/one"))
  let chat = state.active
  chat.queued["next"] = "queued prompt"
  state.notification(
    AgentStarted({
      run_id: "next-run",
      submission_id: Some("next"),
      engine: None,
      model: None,
      max_steps: None,
      session: chat.key.session,
      session_root: Some("/one/.openseek"),
    }),
  )
  assert_true(chat.queued.is_empty())
  assert_eq(chat.pending.get("next"), Some("queued prompt"))
  chat.append_item({
    sequence: 1,
    ts: None,
    item: User({
      content: Content([Text("queued prompt")]),
      submission_id: Some("next"),
    }),
  })
  assert_true(chat.pending.is_empty())
}

///|
test "canonical workspace rebinding preserves the same composer object" {
  let state = State(Some("~/project"))
  let chat = state.active
  let old = chat.key
  chat.draft.insert("unsent")
  state.bind_workspace(chat, "/home/user/project")
  assert_eq(chat.key.workspace, Some("/home/user/project"))
  assert_true(!state.chats.contains(old))
  assert_true(
    state.chats
    .get(chat.key)
    .map(candidate => physical_equal(candidate, chat))
    .unwrap_or(false),
  )
  assert_eq(chat.draft.text(), "unsent")
  assert_true(state.sidebar == [chat.key])
}

///|
test "settings follow provider defaults and preserve compatible explicit models" {
  let state = State(None)
  let settings : @protocol.SettingsStatusPayload = {
    revision: 1,
    provider: "glm",
    custom_api_url: None,
    has_deepseek_key: false,
    has_glm_key: true,
    has_custom_key: false,
    followup_behavior: "steer",
  }
  state.apply_settings(settings)
  assert_eq(state.model, "glm-5.3")
  state.model = "glm-custom-model"
  state.model_explicit = true
  state.apply_settings({ ..settings, revision: 2, })
  assert_eq(state.model, "glm-custom-model")
  state.apply_settings({ ..settings, revision: 3, provider: "deepseek", })
  assert_eq(state.model, "deepseek-flash")
  state.apply_settings(settings)
  assert_eq(state.settings.map(value => value.revision), Some(3))
}

///|
test "an older snapshot cannot discard already committed history" {
  let chat = test_chat("/one")
  chat.commit(commit("/one", 1, "kept"))
  chat.snapshot({
    session: {
      version: Some(1),
      id: Some("same-id"),
      system_prompt: None,
      events: Some([]),
    },
    watermark: Some(0),
    prediction: None,
  })
  assert_eq(chat.watermark, 1)
  assert_eq(chat.rows[0].text, "kept")
  assert_true(chat.needs_reload)
}

///|
async test "queued receipt before the RPC reply cannot restore a consumed message" {
  let release : @async.Queue[Unit] = Queue(kind=Blocking(1))
  with_terminal_peer(
    socket => {
      let (id, params) = terminal_request(socket, "agent.queue")
      let payload : @protocol.QueuePayload = @json.from_json(params)
      guard payload.action is QueueAdd(id=submission, text~, ..) else {
        fail("expected queued addition")
      }
      let event = @protocol.Notification::AgentEvent({
        session: "queued-race",
        run_id: Some("run"),
        event: @agent_protocol.Event::SteerApplied(
          kind="queued",
          content=Content([Text(text)]),
          submission_id=Some(submission),
        ),
      })
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "method": event.wire_name(),
            "params": event.params(),
          } : Json).stringify(),
      )
      release.get()
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "id": id,
            "result": @protocol.QueueReply::{ accepted: true, }.to_json(),
          } : Json).stringify(),
      )
    },
    client => {
      let state = State(None)
      let chat = Chat({
        session: "queued-race",
        workspace: Some("/one"),
        archived: false,
      })
      state.active = chat
      state.chats[chat.key] = chat
      chat.loaded = true
      chat.run_id = Some("run")
      state.queue_followup = true
      @async.with_task_group(group => {
        let sending = group.spawn(() => state.send_prompt(client, "next"))
        let event = client.receive()
        assert_true(!chat.queued.is_empty())
        state.notification(event)
        assert_true(chat.queued.is_empty())
        release.put(())
        sending.wait()
        assert_true(chat.queued.is_empty())
        assert_true(chat.pending.is_empty())
      })
    },
  )
}
