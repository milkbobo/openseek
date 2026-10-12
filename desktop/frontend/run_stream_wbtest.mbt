///|
test "assistant deltas accumulate into the streaming response" {
  let dispatch = test_dispatch()
  let (_, first) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantDelta("Hello"), session=None),
    running_model(),
  )
  let (_, second) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantDelta(", world"), session=None),
    first,
  )
  assert_eq(second.active().turn.streaming_response, Some("Hello, world"))
  inspect(second.active().messages.length(), content="0")
}

///|
test "update is pure: replaying a delta on the same model is idempotent" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("partial"),
    },
  })
  let (_, once) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantDelta("!"), session=None),
    model,
  )
  let (_, twice) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantDelta("!"), session=None),
    model,
  )
  assert_eq(once.active().turn.streaming_response, Some("partial!"))
  assert_eq(twice.active().turn.streaming_response, Some("partial!"))
}

///|
test "deltas from an unknown run are dropped" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r99"), AssistantDelta("stale"), session=None),
    running_model(),
  )
  assert_eq(next.active().turn.streaming_response, None)
}

///|
test "reasoning message waits for its durable commit" {
  let dispatch = test_dispatch()
  let model = running_model()
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("full thought"), session=None),
    model,
  )
  inspect(next.active().messages.length(), content="0")
  assert_eq(
    next.active().turn.live_reasoning,
    Some({ content: "full thought", complete: true, }),
  )
}

///|
test "reasoning deltas accumulate and answer output closes the live stream" {
  let dispatch = test_dispatch()
  let (_, first) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta("first"), session=None),
    running_model(),
  )
  let (_, second) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta(" line"), session=None),
    first,
  )
  assert_eq(
    second.active().turn.live_reasoning,
    Some({ content: "first line", complete: false, }),
  )
  let (_, answered) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantDelta("answer"), session=None),
    second,
  )
  assert_eq(
    answered.active().turn.live_reasoning,
    Some({ content: "first line", complete: true, }),
  )
  // Once the stream is semantically complete, a delayed delta cannot revive
  // or extend it.
  let (_, late) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta(" late"), session=None),
    answered,
  )
  assert_eq(
    late.active().turn.live_reasoning,
    answered.active().turn.live_reasoning,
  )
}

///|
test "an empty remote reasoning settlement clears the partial preview" {
  let dispatch = test_dispatch()
  let (_, partial) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta("first line"), session=None),
    running_model(),
  )
  let (_, settled) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningMessage(""), session=None),
    partial,
  )
  assert_eq(settled.active().turn.live_reasoning, None)
  assert_eq(settled.active().reasoning_for_render(), (None, false))
}

///|
test "a matching durable commit de-duplicates without mutating the preview" {
  let dispatch = test_dispatch()
  let live = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      live_reasoning: Some({ content: "think", complete: true, }),
    },
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
    live,
  )
  assert_eq(
    committed.active().turn.live_reasoning,
    Some({ content: "think", complete: true, }),
  )
  assert_eq(committed.active().reasoning_for_render(), (None, true))
  assert_eq(committed.active().messages.length(), 1)
  assert_true(
    committed.active().messages[0].kind
    is Assistant(reasoning=Some("think"), ..),
  )
}

///|
test "commit-first reasoning keeps late prefixes and de-duplicates when sealed" {
  let dispatch = test_dispatch()
  let commit = SessionCommitted(
    session="desktop-test",
    sequence=1,
    ts=None,
    item=@protocol.Assistant({
      content: "answer",
      tool_calls: None,
      reasoning_content: Some("complete thought"),
      is_replay: None,
    }),
    session_root=@interop.ChannelId::Local.test_store_root(),
  )
  let (_, committed) = update_dev(dispatch, commit, running_model())
  let (_, partial) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta("complete"), session=None),
    committed,
  )
  assert_eq(partial.active().reasoning_for_render(), (Some("complete"), false))
  let (_, completed) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("complete thought"), session=None),
    partial,
  )
  assert_eq(
    completed.active().turn.live_reasoning,
    Some({ content: "complete thought", complete: true, }),
  )
  assert_eq(completed.active().reasoning_for_render(), (None, true))
}

///|
test "a delayed untagged commit cannot truncate a newer reasoning stream" {
  let dispatch = test_dispatch()
  let (_, partial) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta("shared"), session=None),
    running_model(),
  )
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.Assistant({
        content: "older answer",
        tool_calls: None,
        reasoning_content: Some("shared"),
        is_replay: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    partial,
  )
  assert_eq(
    committed.active().turn.live_reasoning,
    Some({ content: "shared", complete: false, }),
  )
  assert_eq(committed.active().reasoning_for_render(), (Some("shared"), false))
  let (_, continued) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta(" future"), session=None),
    committed,
  )
  assert_eq(
    continued.active().turn.live_reasoning,
    Some({ content: "shared future", complete: false, }),
  )
}

///|
test "a later run does not confuse identical historical reasoning for its commit" {
  let dispatch = test_dispatch()
  let historical = {
    ..running_conversation(),
    messages: [
      {
        kind: Assistant(
          reasoning=Some("shared opening"),
          prose=Some("older answer"),
          calls=[],
          replay=false,
          finished=false,
        ),
        ts: None,
        sequence: Some(2),
      },
    ],
    watermark: 3,
    turn: RunState::for_run(3),
  }
  let model = running_model().replace_conversation(historical)
  let (_, partial) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningDelta("shared opening"), session=None),
    model,
  )
  assert_eq(
    partial.active().reasoning_for_render(),
    (Some("shared opening"), false),
  )
  let (_, complete) = update_dev(
    dispatch,
    Engine(Some("r7"), ReasoningMessage("shared opening"), session=None),
    partial,
  )
  assert_eq(
    complete.active().turn.live_reasoning,
    Some({ content: "shared opening", complete: true, }),
  )
}

///|
test "a new model step advances past identical reasoning from the prior step" {
  let previous_step = {
    ..running_conversation(),
    messages: [
      {
        kind: Assistant(
          reasoning=Some("shared opening"),
          prose=None,
          calls=[],
          replay=false,
          finished=false,
        ),
        ts: None,
        sequence: Some(2),
      },
    ],
    watermark: 2,
    turn: {
      ..RunState::for_run(0),
      live_reasoning: Some({ content: "old live", complete: true, }),
    },
  }
  let (_, next_step) = apply_engine_event(
    previous_step,
    AgentStep(Some(2)),
    Some("r7"),
  )
  assert_eq(next_step.turn.live_reasoning, None)
  assert_eq(next_step.turn.reasoning_frontier, 2)
  let (_, live) = apply_engine_event(
    next_step,
    ReasoningDelta("shared opening"),
    Some("r7"),
  )
  assert_eq(live.reasoning_for_render(), (Some("shared opening"), false))
}

///|
test "a new run frontier includes commits already buffered by reload" {
  let dispatch = test_dispatch()
  let buffered : BufferedCommit = {
    sequence: 3,
    ts: None,
    item: @protocol.Assistant({
      content: "older answer",
      tool_calls: None,
      reasoning_content: Some("shared opening"),
      is_replay: None,
    }),
  }
  let conv = {
    ..test_conversation(),
    watermark: 1,
    sync: test_reloading([buffered]),
  }
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="r7",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    test_model().replace_conversation(conv),
  )
  assert_eq(started.active().turn.reasoning_frontier, 3)
}

///|
test "the run heartbeat projects the phase it is derived from" {
  assert_eq(test_conversation().run_heartbeat(), None)
  let stage_of = (conv : Conversation) => {
    conv.run_heartbeat().map(run => run.stage)
  }
  // A silent model call is the whole point of the row: nothing else on screen
  // moves between the step event and the first answer delta.
  assert_eq(stage_of(running_conversation()), Some(Thinking))
  assert_eq(
    stage_of({
      ..running_conversation(),
      run: Open(run_id="r7", stage=AtStep(Some(3))),
    }),
    Some(AtStep(3)),
  )
  assert_eq(
    stage_of({
      ..running_conversation(),
      run: Open(run_id="r7", stage=AtStep(None)),
    }),
    Some(Working),
  )
  assert_eq(
    stage_of({
      ..running_conversation(),
      run: Open(run_id="r7", stage=Cancelling),
    }),
    Some(Stopping),
  )
  // The send is accepted but no run id exists yet: still worth a row, or the
  // gap between submitting and `started` reads as a dropped prompt.
  assert_eq(
    stage_of({ ..test_conversation(), run: Starting(submission_id="sub-1"), }),
    Some(Starting),
  )
  // A finished run leaves nothing behind — the answer is the status.
  assert_eq(
    stage_of({
      ..running_conversation(),
      run: NoRun(ended=Some(RunFinished(Completed))),
    }),
    None,
  )
}

///|
test "the run heartbeat carries only the facts the page actually has" {
  let full = {
    ..running_conversation(),
    run_started_ms: Some(1_000.0),
    turn: { ..running_conversation().turn, usage_tokens: 12_345, },
  }
  assert_eq(
    full.run_heartbeat(),
    Some({ stage: Thinking, started_ms: Some(1_000.0), tokens: 12_345, }),
  )
  // A run adopted from a reconnect has no start this page witnessed. The
  // composer omits the span rather than dating it from when we noticed.
  assert_eq(
    { ..full, run_started_ms: None, }.run_heartbeat().map(run => run.started_ms),
    Some(None),
  )
}

///|
test "a step event is what moves the heartbeat's stage" {
  let running = running_model()
  assert_eq(
    running.active().run_heartbeat().map(run => run.stage),
    Some(Thinking),
  )
  let (_, stepped) = update_dev(
    test_dispatch(),
    Engine(Some("r7"), AgentStep(Some(2)), session=None),
    running,
  )
  assert_eq(
    stepped.active().run_heartbeat().map(run => run.stage),
    Some(AtStep(2)),
  )
}

///|
test "assistant message only settles the transient response" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: { ..running_conversation().turn, streaming_response: Some("answ"), },
  })
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantMessage("answer"), session=None),
    model,
  )
  assert_eq(next.active().turn.streaming_response, None)
  inspect(next.active().messages.length(), content="0")
}

///|
test "agent setup failure is lifecycle-only until its durable terminal" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("partial answer"),
    },
  })
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r7"), AgentSetupFailed("could not initialize"), session=None),
    model,
  )
  assert_eq(next.active().turn.streaming_response, None)
  inspect(next.active().messages.length(), content="0")
}

///|
test "a new agent step clears the live stream" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: { ..running_conversation().turn, streaming_response: Some("left"), },
  })
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r7"), AgentStep(Some(2)), session=None),
    model,
  )
  assert_eq(next.active().turn.streaming_response, None)
}

///|
test "a stream retry clears previews and shows the retry until a delta lands" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r7", stage=AtStep(Some(2))),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("left"),
      live_reasoning: Some({ content: "old thought", complete: false, }),
    },
  })
  let (_, retrying) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      StreamRetry(
        attempt=2,
        max_attempts=5,
        reason="Stream ended before [DONE]",
      ),
      session=None,
    ),
    model,
  )
  let conv = retrying.active()
  assert_eq(conv.turn.streaming_response, None)
  assert_eq(conv.turn.live_reasoning, None)
  assert_true(conv.run is Open(run_id="r7", stage=AtStep(Some(2))))
  assert_true(
    conv.run_heartbeat()
    is Some(
      {
        stage: Retrying(
          attempt=2,
          max_attempts=5,
          reason="Stream ended before [DONE]"
        ),
        ..
      }
    ),
  )
  // The replacement attempt's first delta ends the notice.
  let (_, streaming) = update_dev(
    dispatch,
    Engine(Some("r7"), AssistantDelta("again"), session=None),
    retrying,
  )
  assert_eq(streaming.active().turn.streaming_response, Some("again"))
  assert_true(
    streaming.active().run_heartbeat() is Some({ stage: AtStep(2), .. }),
  )
}

///|
test "a retry notice ends at the model's next progress, not at unrelated events" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r7", stage=AtStep(Some(2))),
  })
  let (_, retrying) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      StreamRetry(attempt=2, max_attempts=5, reason="connection reset"),
      session=None,
    ),
    model,
  )
  // A background job finishing while the engine waits says nothing about
  // the request being retried.
  let (_, still) = update_dev(
    dispatch,
    Engine(Some("r7"), BackgroundNotice("job done"), session=None),
    retrying,
  )
  assert_true(
    still.active().run_heartbeat()
    is Some({ stage: Retrying(attempt=2, ..), .. }),
  )
  // A tool-only response streams no deltas; its usage report is the first
  // sign the replacement attempt completed.
  let (_, resumed) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      Usage(prompt_tokens=10, completion_tokens=5),
      session=None,
    ),
    still,
  )
  assert_true(
    resumed.active().run_heartbeat() is Some({ stage: AtStep(2), .. }),
  )
}

///|
test "finished run clears any leftover stream" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("leftover"),
    },
  })
  let (_, next) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    model,
  )
  assert_eq(next.active().turn.streaming_response, None)
  inspect(next.active().is_running(), content="false")
}

///|
test "an idle background notice is absorbed without a toast" {
  let dispatch = test_dispatch()
  // The run already finished: `active_run_id` is cleared, only the last-run
  // memory ties the id back to its conversation — so the event still reaches
  // `apply_engine_event`, which must raise nothing.
  let model = test_model().replace_conversation({
    ..test_conversation(),
    last_run_id: Some("r7"),
  })
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      BackgroundNotice("background job bg-1 finished (exit=0)"),
      session=None,
    ),
    model,
  )
  assert_true(next.notifications.is_empty())
}
