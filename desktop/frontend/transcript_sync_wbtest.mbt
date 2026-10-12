///|
test "finished run reloads the named durable session for an old host" {
  let dispatch = test_dispatch()
  let (_, finished) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    running_model(),
  )
  guard finished.active().sync
    is Reloading(generation=1, reload_after_current=false, ..) else {
    fail("Finished did not start the compatibility snapshot")
  }
  // Old hosts send no session.event; their post-Finished full snapshot is
  // therefore the only canonical source the commit-aware frontend consumes.
  let (_, loaded) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("question")])),
          ts: None,
          sequence: None,
        },
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("done"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: None,
        },
      ],
      watermark=3,
      generation=1,
    ),
    finished,
  )
  inspect(loaded.active().messages.length(), content="2")
  assert_eq(loaded.active().messages[1].text(), Some("done"))
  inspect(loaded.active().watermark, content="3")
  assert_true(loaded.active().sync is Synced)
}

///|
test "Finished queues one follow-up behind an older in-flight snapshot" {
  let dispatch = test_dispatch()
  let model = {
    ..running_model().replace_conversation({
      ..running_conversation(),
      sync: test_reloading([]),
    }),
    transcript_request_generation: 1,
  }
  let finish : DeviceMsg = Finished(run_id="r7", status="finished", answer=None)
  let (_, finished) = update_dev(dispatch, finish, model)
  guard finished.active().sync
    is Reloading(generation=1, reload_after_current=true, ..) else {
    fail("Finished did not remember the post-boundary reload")
  }
  // A duplicate lifecycle notification is idempotent: it is not a second
  // durable boundary and must not queue another generation.
  let (_, duplicate) = update_dev(dispatch, finish, finished)
  guard duplicate.active().sync
    is Reloading(generation=1, reload_after_current=true, ..) else {
    fail("duplicate Finished changed the queued follow-up")
  }
  let (_, followed) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[],
      watermark=0,
      generation=1,
    ),
    duplicate,
  )
  guard followed.active().sync
    is Reloading(generation=2, reload_after_current=false, ..) else {
    fail("the older snapshot did not hand off to one fresh generation")
  }
}

///|
test "a live commit dates its row on arrival, buffered or applied straight" {
  let dispatch = test_dispatch()
  let stamped = (session, sequence, ts) => {
    SessionCommitted(
      session~,
      sequence~,
      ts=Some(ts),
      item=@protocol.User({
        content: Content([Text("question")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    )
  }
  // The contiguous-commit path a running conversation takes: the row must
  // carry its stamp now, not only after the next snapshot reload.
  let (_, direct) = update_dev(
    dispatch,
    stamped("desktop-test", 1, 1781144351123),
    running_model(),
  )
  assert_true(direct.active().messages[0].ts is Some(1781144351123))
  // The same stamp survives the buffer a reconnect drains commits through.
  let (_, reconnecting) = update_dev(dispatch, BridgeReady, running_model())
  let (_, buffered) = update_dev(
    dispatch,
    stamped("desktop-test", 1, 1781144352000),
    reconnecting,
  )
  let (_, drained) = update_dev(
    dispatch,
    SessionRefreshed(
      session="desktop-test",
      items=[],
      watermark=0,
      generation=1,
      goal=None,
      goal_markers=[],
      prediction=None,
    ),
    buffered,
  )
  assert_true(drained.active().messages[0].ts is Some(1781144352000))
}

///|
test "a foreign background run schedules one causal read after Started" {
  let dispatch = test_dispatch()
  let session = "desktop-background"
  let conv = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      session,
      @interop.ChannelId::Local.test_project(),
    ),
    watermark: 1,
    sync: test_reloading([]),
  }
  let model = {
    ..test_model().replace_conversation(conv),
    transcript_request_generation: 1,
  }
  // This previous-run answer arrived behind a snapshot whose read cut was
  // already taken, but before the next run's lifecycle announcement.
  let (_, buffered_answer) = update_dev(
    dispatch,
    SessionCommitted(
      session~,
      sequence=2,
      ts=None,
      item=@protocol.Assistant({
        content: "previous answer",
        tool_calls: None,
        reasoning_content: None,
        is_replay: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="foreign-next",
      session~,
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    buffered_answer,
  )
  guard started.find_conversation(@interop.ChannelId::Local, session)
    is Some(started_conv) else {
    fail("missing background conversation")
  }
  assert_true(
    started_conv.sync is Reloading(generation=1, reload_after_current=true, ..),
  )
  let (_, buffered_terminal) = update_dev(
    dispatch,
    SessionCommitted(
      session~,
      sequence=3,
      ts=None,
      item=@protocol.Terminal(@protocol.Finished("previous answer")),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    started,
  )
  let (_, buffered_user) = update_dev(
    dispatch,
    SessionCommitted(
      session~,
      sequence=4,
      ts=None,
      item=@protocol.User({
        content: Content([Text("current question")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    buffered_terminal,
  )
  // Generation 1 predates Started. It may drain the ordered buffer, and the
  // causal read it scheduled still runs after it.
  let (_, after_old_cut) = update_dev(
    dispatch,
    SessionRefreshed(
      session~,
      items=[],
      watermark=1,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation=1,
    ),
    buffered_user,
  )
  guard after_old_cut.find_conversation(@interop.ChannelId::Local, session)
    is Some(after_old) else {
    fail("missing conversation after old snapshot")
  }
  assert_true(after_old.sync is Reloading(generation=2, ..))
  let (_, causal) = update_dev(
    dispatch,
    SessionRefreshed(
      session~,
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("previous answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: None,
        },
        {
          kind: User(content=Content([Text("current question")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=4,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation=2,
    ),
    after_old_cut,
  )
  guard causal.find_conversation(@interop.ChannelId::Local, session)
    is Some(current) else {
    fail("missing conversation after causal snapshot")
  }
  assert_true(current.sync is Synced)
  inspect(current.messages.length(), content="2")
}

///|
test "buffered commits are delivery, not applied chronology" {
  let dispatch = test_dispatch()
  let conv = {
    ..running_conversation(),
    watermark: 1,
    sync: test_reloading([]),
  }
  let model = test_model().replace_conversation(conv)
  let (_, user) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=2,
      ts=None,
      item=@protocol.User({
        content: Content([Text("current question")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  let (_, answer) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=3,
      ts=None,
      item=@protocol.Assistant({
        content: "current answer",
        tool_calls: None,
        reasoning_content: None,
        is_replay: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    user,
  )
  let (_, terminal) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=4,
      ts=None,
      item=@protocol.Terminal(@protocol.Finished("current answer")),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    answer,
  )
  // Buffered state is delivery, not applied chronology: three commits have
  // arrived and none of them has moved the transcript.
  inspect(terminal.active().watermark, content="1")
  inspect(terminal.active().messages.length(), content="0")
  let (_, loaded) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[],
      watermark=1,
      generation=1,
    ),
    terminal,
  )
  // The snapshot lands and the ordered buffer drains on top of it. The
  // terminal projects no row of its own.
  inspect(loaded.active().watermark, content="4")
  inspect(loaded.active().messages.length(), content="2")
}

///|
test "send does not show a prompt until its commit lands" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    task: "build the thing",
  })
  let (_, sent) = update(dispatch, Send, model)
  // Starting the request changes lifecycle/composer state only.
  inspect(sent.active().messages.length(), content="0")
  inspect(sent.active().watermark, content="0")
  // The durable commit is the first point the prompt becomes transcript.
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("build the thing")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    sent,
  )
  inspect(committed.active().messages.length(), content="1")
  guard committed.active().messages[0].kind is User(..) else {
    fail("expected a user item")
  }
  inspect(committed.active().watermark, content="1")
}

///|
test "a replayed commit at or below the watermark is dropped" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [
      {
        kind: User(content=Content([Text("already there")])),
        ts: None,
        sequence: None,
      },
    ],
    watermark: 2,
  })
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=2,
      ts=None,
      item=@protocol.User({
        content: Content([Text("already there")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  inspect(next.active().messages.length(), content="1")
  inspect(next.active().watermark, content="2")
}

///|
test "a commit past the frontier buffers and flips into a reload" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    watermark: 1,
  })
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=5,
      ts=None,
      item=@protocol.User({
        content: Content([Text("from the future")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  // The gap means missed broadcasts; nothing is applied out of order.
  inspect(next.active().messages.length(), content="0")
  inspect(next.active().watermark, content="1")
  guard next.active().sync is Reloading(buffered~, ..) else {
    fail("expected a reload in flight")
  }
  inspect(buffered.length(), content="1")
  inspect(buffered[0].sequence, content="5")
}

///|
test "commits buffer while a reload is in flight" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    sync: test_reloading([]),
  })
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=3,
      ts=None,
      item=@protocol.User({
        content: Content([Text("mid-reload")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  inspect(next.active().messages.length(), content="0")
  guard next.active().sync is Reloading(buffered~, ..) else {
    fail("expected the reload to stay in flight")
  }
  inspect(buffered.length(), content="1")
}

///|
test "a snapshot drains buffered commits in sequence order" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation()
    // Out of arrival order on purpose; the drain sorts by sequence.
    ,
    sync: test_reloading([
      {
        sequence: 4,
        ts: None,
        item: @protocol.User({
          content: Content([Text("four")]),
          submission_id: None,
        }),
      },
      {
        sequence: 3,
        ts: None,
        item: @protocol.User({
          content: Content([Text("three")]),
          submission_id: None,
        }),
      },
    ]),
  })
  let (_, next) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("one")])),
          ts: None,
          sequence: None,
        },
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("two"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: None,
        },
      ],
      watermark=2,
      generation=1,
    ),
    model,
  )
  inspect(next.active().messages.length(), content="4")
  assert_eq(next.active().messages[2].text(), Some("three"))
  assert_eq(next.active().messages[3].text(), Some("four"))
  inspect(next.active().watermark, content="4")
  assert_true(next.active().sync is Synced)
}

///|
test "a snapshot already containing the buffered commits drops them" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    sync: test_reloading([
      {
        sequence: 2,
        ts: None,
        item: @protocol.User({
          content: Content([Text("dup")]),
          submission_id: None,
        }),
      },
    ]),
  })
  let (_, next) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("one")])),
          ts: None,
          sequence: None,
        },
        {
          kind: User(content=Content([Text("dup")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=2,
      generation=1,
    ),
    model,
  )
  inspect(next.active().messages.length(), content="2")
  inspect(next.active().watermark, content="2")
  assert_true(next.active().sync is Synced)
}

///|
test "a snapshot with a still-gapped buffer keeps reloading" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    sync: test_reloading([
      {
        sequence: 9,
        ts: None,
        item: @protocol.User({
          content: Content([Text("far")]),
          submission_id: None,
        }),
      },
    ]),
  })
  let (_, next) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("one")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=2,
      generation=1,
    ),
    model,
  )
  inspect(next.active().watermark, content="2")
  guard next.active().sync is Reloading(buffered~, ..) else {
    fail("expected another reload for the remaining gap")
  }
  inspect(buffered.length(), content="1")
  inspect(buffered[0].sequence, content="9")
}

///|
test "background retries preserve buffered commits until a later success" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [
      { kind: User(content=Content([Text("kept")])), ts: None, sequence: None, },
    ],
    watermark: 1,
    sync: test_reloading([
      {
        sequence: 3,
        ts: None,
        item: @protocol.User({
          content: Content([Text("x")]),
          submission_id: None,
        }),
      },
    ]),
  })
  let model = { ..model, transcript_request_generation: 1, }
  let failure = SessionRefreshFailed(session="desktop-test", generation=1)
  let (_, retrying2) = update_dev(dispatch, failure, model)
  guard retrying2.active().sync is Reloading(attempt=2, buffered=buffered2, ..) else {
    fail("expected the second background attempt")
  }
  inspect(buffered2.length(), content="1")
  let (_, retrying3) = update_dev(dispatch, failure, retrying2)
  guard retrying3.active().sync is Reloading(attempt=3, ..) else {
    fail("expected the third background attempt")
  }
  let (_, failed) = update_dev(dispatch, failure, retrying3)
  guard failed.active().sync is ReloadFailed(buffered=failed_buffer, ..) else {
    fail("expected bounded retry exhaustion")
  }
  inspect(failed_buffer.length(), content="1")
  inspect(failed.active().messages.length(), content="1")
  inspect(failed.notifications.length(), content="0")
  // The next commit starts a fresh generation without applying out of order.
  let (_, retrying) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=2,
      ts=None,
      item=@protocol.User({
        content: Content([Text("next")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    failed,
  )
  guard retrying.active().sync
    is Reloading(generation=2, buffered=retry_buffer, ..) else {
    fail("expected a new generation")
  }
  inspect(retry_buffer.length(), content="2")
  let (_, healed) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("kept")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=1,
      generation=2,
    ),
    retrying,
  )
  inspect(healed.active().messages.length(), content="3")
  assert_eq(healed.active().messages[1].text(), Some("next"))
  assert_eq(healed.active().messages[2].text(), Some("x"))
  inspect(healed.active().watermark, content="3")
  assert_true(healed.active().sync is Synced)
}

///|
test "reopening an active failed reload restarts it and keeps the buffer" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [
      { kind: User(content=Content([Text("kept")])), ts: None, sequence: None, },
    ],
    watermark: 1,
    sync: ReloadFailed(generation=1, buffered=[
      {
        sequence: 2,
        ts: None,
        item: @protocol.User({
          content: Content([Text("two")]),
          submission_id: None,
        }),
      },
    ]),
  })
  let model = { ..model, transcript_request_generation: 1, }
  let (_, reopened) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-test"),
    model,
  )
  assert_true(
    reopened.loading_conversation
    is Some({ channel: Local, session: "desktop-test", }),
  )
  guard reopened.active().sync
    is Reloading(generation=2, attempt=1, buffered~, ..) else {
    fail("expected the active click to restart the reload")
  }
  inspect(buffered.length(), content="1")
  let (_, loaded) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("kept")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=1,
      generation=2,
    ),
    reopened,
  )
  assert_true(loaded.loading_conversation is None)
  inspect(loaded.active().messages.length(), content="2")
  inspect(loaded.active().watermark, content="2")
  assert_true(loaded.active().sync is Synced)
}

///|
test "stale and lower-watermark snapshots cannot overwrite current state" {
  let dispatch = test_dispatch()
  let current_root = @interop.ChannelId::Local.test_resource("/work/current")
  let model = test_model().replace_conversation({
    ..test_conversation(),
    workspace: Project(root=current_root),
    messages: [
      {
        kind: User(content=Content([Text("current")])),
        ts: None,
        sequence: None,
      },
    ],
    watermark: 5,
    sync: Reloading(
      generation=2,
      attempt=1,
      buffered=[
        {
          sequence: 6,
          ts: None,
          item: @protocol.User({
            content: Content([Text("six")]),
            submission_id: None,
          }),
        },
      ],
      reload_after_current=false,
    ),
  })
  let (_, stale) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("stale generation")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=9,
      generation=1,
    ),
    model,
  )
  assert_eq(stale.active().messages[0].text(), Some("current"))
  inspect(stale.active().watermark, content="5")
  assert_eq(stale.active().workspace, Project(root=current_root))
  guard stale.active().sync is Reloading(generation=2, attempt=1, ..) else {
    fail("stale generation changed the active reload")
  }
  let (_, lower) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("older snapshot")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=4,
      generation=2,
    ),
    stale,
  )
  assert_eq(lower.active().messages[0].text(), Some("current"))
  inspect(lower.active().watermark, content="5")
  assert_eq(lower.active().workspace, Project(root=current_root))
  guard lower.active().sync is Reloading(generation=2, attempt=2, buffered~, ..) else {
    fail("lower watermark did not retry the current generation")
  }
  inspect(buffered.length(), content="1")
}

///|
test "tool decode semantics wait for their durable error tool result" {
  let dispatch = test_dispatch()
  let semantic = Engine(
    Some("r7"),
    ToolCallDecodeError(tool_name="edit", reason="invalid arguments"),
    session=None,
  )
  // The engine records the response with its undecodable call, then the
  // error result that closes it; the semantic event is only news.
  let call = SessionCommitted(
    session="desktop-test",
    sequence=1,
    ts=None,
    item=@protocol.Assistant({
      content: "",
      tool_calls: Some([{ id: "c1", name: "edit", arguments: "{", }]),
      reasoning_content: None,
      is_replay: None,
    }),
    session_root=@interop.ChannelId::Local.test_store_root(),
  )
  let result = SessionCommitted(
    session="desktop-test",
    sequence=2,
    ts=None,
    item=@protocol.ToolResult({
      data: None,
      tool_call_id: "c1",
      tool_name: "edit",
      content: Content([Text("invalid arguments")]),
      is_error: true,
      brief: None,
    }),
    session_root=@interop.ChannelId::Local.test_store_root(),
  )
  let (_, semantic_first) = update_dev(dispatch, semantic, running_model())
  inspect(semantic_first.active().messages.length(), content="0")
  let (_, called) = update_dev(dispatch, call, semantic_first)
  let (_, committed_after) = update_dev(dispatch, result, called)
  inspect(committed_after.active().messages.length(), content="1")
  guard committed_after.active().messages[0].kind is Assistant(calls=[edit], ..) else {
    fail("expected the response carrying the failed call")
  }
  assert_true(
    edit.outcome
    is Done(content=Content([Text("invalid arguments")]), is_error=true, ..),
  )
  let (_, called_first) = update_dev(dispatch, call, running_model())
  let (_, committed_first) = update_dev(dispatch, result, called_first)
  let (_, semantic_after) = update_dev(dispatch, semantic, committed_first)
  inspect(semantic_after.active().messages.length(), content="1")
}

///|
test "assistant semantic events wait for their durable commit" {
  let dispatch = test_dispatch()
  let (_, thought) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("think"), session=None),
    running_model(),
  )
  let (_, answered) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantMessage("answer"), session=None),
    thought,
  )
  inspect(answered.active().messages.length(), content="0")
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.Assistant({
        content: "answer",
        tool_calls: None,
        reasoning_content: Some("think"),
        is_replay: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    answered,
  )
  // One durable item projects as one response, thought and answer together.
  inspect(committed.active().messages.length(), content="1")
  assert_true(
    committed.active().messages[0].kind
    is Assistant(reasoning=Some("think"), ..),
  )
  assert_eq(committed.active().messages[0].text(), Some("answer"))
  inspect(committed.active().watermark, content="1")
}

///|
test "a committed tool result visibly changes its existing call row" {
  let (_, called) = running_conversation().apply_commit(
    1,
    @protocol.Assistant({
      content: "",
      tool_calls: Some([
        { id: "c1", name: "read", arguments: "{\"path\":\"moon.mod\"}", },
      ]),
      reasoning_content: None,
      is_replay: None,
    }),
  )
  inspect(called.messages.length(), content="1")
  let (changed, completed) = called.apply_commit(
    2,
    @protocol.ToolResult({
      data: None,
      tool_call_id: "c1",
      tool_name: "read",
      content: Content([Text("module contents")]),
      is_error: false,
      brief: Some("read moon.mod"),
    }),
  )
  assert_true(changed)
  inspect(completed.messages.length(), content="1")
  guard completed.messages[0].kind is Assistant(calls=[call], ..) else {
    fail("expected the response to keep its one call")
  }
  assert_true(
    call.outcome
    is Done(
      content=Content([Text("module contents")]),
      brief=Some("read moon.mod"),
      ..
    ),
  )
}

///|
test "a delayed assistant commit never clears a newer live delta" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("newer turn fragment"),
      live_reasoning: Some({
        content: "newer reasoning fragment",
        complete: false,
      }),
    },
  })
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.Assistant({
        content: "older committed answer",
        tool_calls: None,
        reasoning_content: Some("older reasoning"),
        is_replay: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  assert_eq(
    committed.active().turn.streaming_response,
    Some("newer turn fragment"),
  )
  assert_eq(
    committed.active().turn.live_reasoning,
    Some({ content: "newer reasoning fragment", complete: false, }),
  )
}

///|
test "a delayed terminal commit never clears a newer live delta" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    messages: [
      {
        kind: User(content=Content([Text("older prompt")])),
        ts: None,
        sequence: None,
      },
    ],
    watermark: 1,
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("next turn fragment"),
    },
  })
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=2,
      ts=None,
      item=@protocol.Terminal(@protocol.Finished("older answer")),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  assert_eq(
    committed.active().turn.streaming_response,
    Some("next turn fragment"),
  )
}

///|
test "commit-first assistant semantics do not append again" {
  let dispatch = test_dispatch()
  let streaming = running_model().replace_conversation({
    ..running_conversation(),
    turn: { ..running_conversation().turn, streaming_response: Some("answer"), },
  })
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.Assistant({
        content: "answer",
        tool_calls: None,
        reasoning_content: Some("think"),
        is_replay: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    streaming,
  )
  let (_, thought) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("think"), session=None),
    committed,
  )
  let (_, answered) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantMessage("answer"), session=None),
    thought,
  )
  inspect(answered.active().messages.length(), content="1")
  inspect(answered.active().watermark, content="1")
  assert_eq(answered.active().turn.streaming_response, None)
}

///|
test "a sequence-one commit materializes an unknown hidden conversation" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-elsewhere",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("hi")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    test_model(),
  )
  inspect(next.conversations.length(), content="2")
  inspect(next.active().messages.length(), content="0")
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-elsewhere")
    is Some(hidden) else {
    fail("unknown commit did not materialize its session")
  }
  inspect(hidden.messages.length(), content="1")
  assert_eq(hidden.messages[0].text(), Some("hi"))
  inspect(hidden.watermark, content="1")
  inspect(next.dev().sessions_request_generation, content="1")
  let (_, repeated) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-elsewhere",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("hi")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    next,
  )
  inspect(repeated.dev().sessions_request_generation, content="1")
}

///|
test "a gapped commit for an unknown session materializes then reloads" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-gap",
      sequence=3,
      ts=None,
      item=@protocol.User({
        content: Content([Text("third")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    test_model(),
  )
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-gap")
    is Some(hidden) else {
    fail("gapped commit did not materialize its session")
  }
  inspect(hidden.messages.length(), content="0")
  guard hidden.sync is Reloading(generation=1, buffered~, ..) else {
    fail("unknown gap did not start a snapshot recovery")
  }
  inspect(buffered.length(), content="1")
  inspect(buffered[0].sequence, content="3")
  inspect(next.active_session, content="desktop-test")
}

///|
test "a late commit cannot resurrect a locally known archived session" {
  let dispatch = test_dispatch()
  let model = test_model().with_dev(dev => {
    ..dev,
    archived: [
      {
        id: "desktop-archived",
        title: Some("archived"),
        workspace: @interop.ChannelId::Local.test_project(),
        workspace_name: "",
        updated_at_ms: None,
      },
    ],
  })
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-archived",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("stale")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  assert_true(
    next.find_conversation(@interop.ChannelId::Local, "desktop-archived")
    is None,
  )
  inspect(next.conversations.length(), content="1")
}

///|
test "an archive tombstone blocks commits before the archived list refreshes" {
  let dispatch = test_dispatch()
  let model = test_model().with_archive_override(
    @interop.ChannelId::Local,
    {
      session: "desktop-tombstoned",
      workspace: @interop.ChannelId::Local.test_project(),
    },
    ArchiveStored,
  )
  let (_, next) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-tombstoned",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("stale")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  assert_true(
    next.find_conversation(@interop.ChannelId::Local, "desktop-tombstoned")
    is None,
  )
  inspect(next.conversations.length(), content="1")
}
