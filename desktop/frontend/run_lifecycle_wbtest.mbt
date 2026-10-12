///|
test "runs resync names exact Starting Open and Idle owners" {
  let starting = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "starting-session",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Starting(submission_id="submission-starting"),
  }
  let open = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "open-session",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Open(run_id="run-open", stage=Opened),
  }
  let idle = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "idle-session",
      @interop.ChannelId::Local.test_project(),
    ),
    last_run_id: Some("run-idle"),
  }
  let empty = empty_conversation(
    @interop.ChannelId::Local,
    "never-started",
    @interop.ChannelId::Local.test_project(),
  )
  let model = test_model()
    .replace_conversation(starting)
    .replace_conversation(open)
    .replace_conversation(idle)
    .replace_conversation(empty)
  let json = runs_payload(
    model.run_snapshot_frontier(@interop.ChannelId::Local),
  ).to_json()
  guard json is { "known": Array(known), .. } else {
    fail("runs payload omitted known selectors")
  }
  inspect(known.length(), content="3")
  assert_true(
    known.contains({
      "session": "starting-session",
      "submission_id": "submission-starting",
    }),
  )
  assert_true(
    known.contains({ "session": "open-session", "run_id": "run-open" }),
  )
  assert_true(
    known.contains({ "session": "idle-session", "run_id": "run-idle" }),
  )
}

///|
/// Run A has finished but its exact start response is still in flight; run B
/// has already been sent and announced on the same conversation.
fn second_run_started_before_first_response() -> (Model, String)? {
  let dispatch = test_dispatch()
  let first = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="first-start"), },
    "first-start",
    "first prompt",
  )
  let (_, first_started) = update_dev(
    dispatch,
    Started(
      run_id="r-first",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some("first-start"),
    ),
    test_model().replace_conversation(first),
  )
  let (_, first_finished) = update_dev(
    dispatch,
    Finished(run_id="r-first", status="finished", answer=None),
    first_started,
  )
  let (_, reconciled) = update_dev(
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
    first_finished,
  )
  let (_, post_finish) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[],
      watermark=1,
      generation=2,
    ),
    reconciled,
  )
  guard post_finish.active_conversation() is Some(idle) else { return None }
  let drafted = post_finish.replace_conversation({
    ..idle,
    task: "second prompt",
  })
  let (_, sending) = update(dispatch, Send, drafted)
  guard sending.active_conversation() is Some(sent) &&
    sent.run is Starting(submission_id=second_submission) else {
    return None
  }
  let (_, second_started) = update_dev(
    dispatch,
    Started(
      run_id="r-second",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some(second_submission),
    ),
    sending,
  )
  Some((second_started, second_submission))
}

///|
test "run semantic errors never duplicate their terminal commit" {
  let dispatch = test_dispatch()
  let semantic = Error(
    run_id=Some("r7"),
    message="engine error",
    diagnostics=None,
    exit_code=None,
  )
  let terminal = SessionCommitted(
    session="desktop-test",
    sequence=1,
    ts=None,
    item=@protocol.Terminal(@protocol.Failed("engine error")),
    session_root=@interop.ChannelId::Local.test_store_root(),
  )
  let (_, semantic_first) = update_dev(dispatch, semantic, running_model())
  let (_, committed_after) = update_dev(dispatch, terminal, semantic_first)
  inspect(committed_after.active().messages.length(), content="1")
  let (_, committed_first) = update_dev(dispatch, terminal, running_model())
  let (_, semantic_after) = update_dev(dispatch, semantic, committed_first)
  inspect(semantic_after.active().messages.length(), content="1")
}

///|
test "a process-exit error reports its host diagnostics as a toast" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    Error(
      run_id=Some("r7"),
      message="engine process exited",
      diagnostics=Some("fatal stderr"),
      exit_code=Some(9),
    ),
    running_model(),
  )
  // The record will never carry this text, so the transcript is the wrong
  // place for it: no durable event can ever say where it belongs.
  inspect(next.notifications.length(), content="1")
  assert_true(next.notifications[0].message.contains("fatal stderr"))
}

///|
test "agent error decoder preserves exit codes and normalizes missing messages" {
  guard error_msg({
      run_id: Some("r7"),
      message: Some("exited"),
      exit_code: Some(9),
      diagnostics: None,
    })
    is Some(Error(exit_code=Some(9), ..)) else {
    fail("expected the exit code")
  }
  guard error_msg({
      run_id: None,
      message: None,
      exit_code: None,
      diagnostics: None,
    })
    is Some(Error(message="error", ..)) else {
    fail("expected the generic error label")
  }
}

///|
test "started routes by session without restating its placement" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    Started(
      run_id="r7",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    test_model(),
  )
  // A rootless Started names no store, so it must not restate placement: the
  // conversation keeps the project it already had.
  assert_true(next.active().workspace is Project(..))
  assert_true(
    next.conversation_root(next.active()) is Some(root) && root.path == "/work",
  )
  inspect(next.active().is_running(), content="true")
  guard next.active().run is Open(run_id="r7", ..) else {
    fail("expected the run id to be recorded")
  }
  // A run this client did not send: the store gained its prompt, so the
  // on-screen conversation re-reads it in the background, buffering commits
  // until the snapshot lands. The user-load marker stays free.
  assert_true(next.active().sync is Reloading(..))
  assert_true(next.loading_conversation is None)
}

///|
test "started decoder preserves optional placement and submission id" {
  guard started_msg(@interop.ChannelId::Local, {
      run_id: "r7",
      submission_id: Some("submission-7"),
      engine: None,
      model: Some("deepseek-v4-pro"),
      max_steps: Some(1000),
      session: "desktop-test",
      session_root: Some("/work/core/.openseek"),
    })
    is Some(Started(session_root~, submission_id~, ..)) else {
    fail("placement or submission id was lost while decoding Started")
  }
  assert_true(
    session_root is Some(resource) && resource.path == "/work/core/.openseek",
  )
  assert_eq(submission_id, Some("submission-7"))
}

///|
test "host path decoders reject relative placement and diagnostic paths" {
  let payload : @protocol.StartedPayload = {
    run_id: "r7",
    submission_id: None,
    engine: None,
    model: Some("deepseek-v4-pro"),
    max_steps: Some(1000),
    session: "desktop-test",
    session_root: Some("relative/session-root"),
  }
  assert_true(started_msg(@interop.ChannelId::Local, payload) is None)
  assert_true(
    RecoveredRun::from_started(@interop.ChannelId::Local, payload) is None,
  )
  assert_true(
    diagnostics_msg(@interop.ChannelId::Local, {
      root: "relative/workspace",
      path: "relative/file.mbt",
      diagnostics: [],
    })
    is None,
  )
}

///|
test "started for an unknown session materializes its conversation" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    Started(
      run_id="r7",
      session="desktop-ghost",
      model=DsPro,
      max_steps=1000,
      session_root=Some(@interop.ChannelId::Local.test_store_root()),
      submission_id=None,
    ),
    test_model(),
  )
  // Another client's run is now trackable here: cancellable, steerable,
  // and its events route to a real conversation.
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-ghost")
    is Some(ghost) else {
    fail("expected the foreign run's conversation to materialize")
  }
  inspect(ghost.is_running(), content="true")
  guard ghost.run is Open(run_id="r7", ..) else {
    fail("expected the run id to be recorded")
  }
  // No bubble is synthesized from the pushed task — the durable transcript's
  // only sources are snapshots and commits, and the prompt's own commit (or
  // the read when this conversation is opened) brings it.
  inspect(ghost.messages.length(), content="0")
  // Focus stays where the user is.
  inspect(next.active_session, content="desktop-test")
  inspect(next.active().is_running(), content="false")
  // A run whose store this page cannot place has no directory to work in
  // and no store to read from, so there is nothing to materialize.
  let (_, rootless) = update_dev(
    dispatch,
    Started(
      run_id="r8",
      session="desktop-rootless",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    test_model(),
  )
  assert_true(
    rootless.find_conversation(@interop.ChannelId::Local, "desktop-rootless")
    is None,
  )
}

///|
/// Started is where a foreign conversation gets its placement, and it
/// precedes the first commit — so on a fresh connection, whose projects
/// registry is still in flight, the run's own store root has to name the
/// project. Otherwise terminal and file operations would have nowhere to
/// point until the session list lands.
test "started places a conversation before the registry arrives" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/foreign")
  let store = @interop.ChannelId::Local.test_resource("/work/foreign/.openseek")
  fn start(model, session, session_root) {
    let (_, next) = update_dev(
      dispatch,
      Started(
        run_id="r9",
        session~,
        model=DsPro,
        max_steps=1000,
        session_root~,
        submission_id=None,
      ),
      model,
    )
    next
  }

  // The registry is empty: the store layout is the only evidence, and it
  // names the project.
  let unregistered = start(test_model(), "desktop-foreign", Some(store))
  guard unregistered.find_conversation(
      @interop.ChannelId::Local,
      "desktop-foreign",
    )
    is Some(placed) else {
    fail("expected the foreign run's conversation to materialize")
  }
  assert_eq(placed.workspace, Project(root=workspace))
  // A registered project resolves the same way it always did.
  let registered = start(
    test_model().with_dev(dev => { ..dev, projects: [workspace], }),
    "desktop-registered",
    Some(store),
  )
  guard registered.find_conversation(
      @interop.ChannelId::Local,
      "desktop-registered",
    )
    is Some(known) else {
    fail("expected the registered run's conversation to materialize")
  }
  assert_eq(known.workspace, Project(root=workspace))
}

///|
test "a run boundary discards the previous turn's live state whole" {
  let dispatch = test_dispatch()
  let lane : @subrun.Lane = {
    id: "sub-1",
    kind: "task",
    label: "sub-run",
    steps: 2,
    activity: "running",
    run: Some("r-old"),
  }
  let conv = {
    ..running_conversation(),
    run: Open(run_id="r-old", stage=AtStep(Some(3))),
    turn: {
      streaming_response: Some("old answer fragment"),
      live_reasoning: None,
      retrying: None,
      reasoning_frontier: 0,
      subruns: [lane],
      usage_tokens: 4200,
    },
  }
  let (_, next) = update_dev(
    dispatch,
    Started(
      run_id="r-new",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    running_model().replace_conversation(conv),
  )
  // Nothing the previous turn accumulated belongs to this one, and none of it
  // has to be cleared field by field to stay out.
  guard next.active().run is Open(run_id="r-new", ..) else {
    fail("expected the new run to replace the old id")
  }
  assert_eq(next.active().turn.streaming_response, None)
  inspect(next.active().turn.subruns.length(), content="0")
  inspect(next.active().turn.usage_tokens, content="0")
}

///|
test "a distinct started id replaces a stale open run as foreign" {
  let dispatch = test_dispatch()
  let conv = with_pending_steers(
    {
      ..running_conversation(),
      run: Open(run_id="r-old", stage=AtStep(Some(3))),
      turn: {
        ..running_conversation().turn,
        streaming_response: Some("old answer fragment"),
      },
      run_started_ms: Some(1_000.0),
    },
    ["old steer"],
    run_id="r-old",
  )
  let model = running_model().replace_conversation(conv)
  let (_, next) = update_dev(
    dispatch,
    Started(
      run_id="r-new",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    model,
  )
  guard next.active().run is Open(run_id="r-new", stage=Opened) else {
    fail("expected the new run to replace the stale id")
  }
  assert_eq(next.active().turn.streaming_response, None)
  inspect(next.active().pending_steers.length(), content="0")
  // The replaced run took its pending input with it and left no placeholder:
  // what the turn actually recorded is in the transcript.
  guard next.active().sync is Reloading(generation=1, attempt=1, ..) else {
    fail("a foreign replacement did not refresh the transcript")
  }
  // The replaced run's start belonged to the run that just lost the seat.
  // Carrying it over would age the new run from a moment it never had.
  assert_eq(next.active().run_started_ms, None)
}

///|
test "a repeated started id is idempotent" {
  let dispatch = test_dispatch()
  let conv = with_pending_steers(
    {
      ..running_conversation(),
      run: Open(run_id="r7", stage=AtStep(Some(4))),
      turn: {
        ..running_conversation().turn,
        streaming_response: Some("current fragment"),
      },
    },
    ["current steer"],
  )
  let model = running_model().replace_conversation(conv)
  let (_, next) = update_dev(
    dispatch,
    Started(
      run_id="r7",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    model,
  )
  guard next.active().run is Open(run_id="r7", stage=AtStep(Some(4))) else {
    fail("a repeated start reset the live run stage")
  }
  assert_eq(next.active().turn.streaming_response, Some("current fragment"))
  inspect(next.active().pending_steers.length(), content="1")
  assert_eq(next.active().pending_steers[0].content, "current steer")
  inspect(next.transcript_request_generation, content="0")
  assert_true(next.active().sync is Synced)
}

///|
test "a start failure cannot close a run opened by a winning push" {
  let dispatch = test_dispatch()
  let starting_conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="mine"), },
    "mine",
    "my competing prompt",
  )
  let starting = test_model().replace_conversation(starting_conv)
  let (_, opened) = update_dev(
    dispatch,
    Started(
      run_id="r-foreign",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some("theirs"),
    ),
    starting,
  )
  let opened = opened.replace_conversation(
    with_pending_steers(
      {
        ..opened.active(),
        turn: {
          ..opened.active().turn,
          streaming_response: Some("foreign fragment"),
        },
      },
      ["steer for foreign run"],
      run_id="r-foreign",
    ),
  )
  let (_, failed) = update_dev(
    dispatch,
    StartRejected(
      session="desktop-test",
      submission_id="mine",
      message="start was rejected",
    ),
    opened,
  )
  guard failed.active().run is Open(run_id="r-foreign", stage=Opened) else {
    fail("the local failure closed the already-open run")
  }
  assert_eq(failed.active().turn.streaming_response, Some("foreign fragment"))
  inspect(failed.active().pending_steers.length(), content="1")
  inspect(
    failed.active().pending_steers[0].content,
    content="steer for foreign run",
  )
  inspect(failed.active().task, content="my competing prompt")
  inspect(failed.notifications.length(), content="1")
  inspect(failed.notifications[0].message, content="start was rejected")
  guard failed.active().sync is Reloading(generation=1, ..) else {
    fail("the raced start failure did not catch up the transcript")
  }
}

///|
test "a start failure closes only a still-starting run" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    {
      ..test_conversation(),
      run: Starting(submission_id="prompt-id"),
      turn: { ..test_conversation().turn, streaming_response: Some("partial"), },
    },
    "prompt-id",
    "prompt",
  )
  let model = test_model().replace_conversation(conv)
  let (_, failed) = update_dev(
    dispatch,
    StartRejected(
      session="desktop-test",
      submission_id="prompt-id",
      message="start failed",
    ),
    model,
  )
  assert_true(failed.active().run is NoRun(ended=Some(RunFailed)))
  assert_eq(failed.active().turn.streaming_response, None)
  inspect(failed.notifications.length(), content="1")
  inspect(failed.active().task, content="prompt")
  inspect(failed.transcript_request_generation, content="0")
}

///|
test "a matching Started establishes the run after an undelivered response" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="prompt-id"), },
    "prompt-id",
    "accepted prompt",
  )
  let (_, failed) = update_dev(
    dispatch,
    StartUndelivered(
      session="desktop-test",
      submission_id="prompt-id",
      message="connection lost",
    ),
    test_model().replace_conversation(conv),
  )
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="r-recovered",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some("prompt-id"),
    ),
    failed,
  )
  // The lost response ended the entry and left no notice behind; a Started
  // that arrives anyway is still the run's exact identity.
  assert_true(started.active().run is Open(run_id="r-recovered", ..))
  inspect(started.active().pending_steers.length(), content="0")
}

///|
test "an accepted start response opens the run without Started" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="prompt-id"), },
    "prompt-id",
    "prompt",
  )
  let (_, responded) = update_dev(
    dispatch,
    StartResponded(
      session="desktop-test",
      submission_id="prompt-id",
      run_id="r-response",
      status="accepted",
      exit_code=0,
    ),
    test_model().replace_conversation(conv),
  )
  assert_true(responded.active().run is Open(run_id="r-response", ..))
  assert_true(responded.active().last_run_id is Some("r-response"))
  // The reply is the entry's last consumer: a prompt is sent once.
  inspect(responded.active().pending_steers.length(), content="0")
  assert_true(responded.active().sync is Reloading(generation=1, ..))
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="r-response",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some("prompt-id"),
    ),
    responded,
  )
  // The delayed Started is idempotent with the response-first recovery: it
  // neither drops nor queues a second generation.
  assert_true(started.active().sync is Reloading(generation=1, ..))
  let (_, loaded) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("external prompt")])),
          ts: None,
          sequence: None,
        },
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("external answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: None,
        },
        {
          kind: User(content=Content([Text("prompt")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=4,
      generation=1,
    ),
    started,
  )
  assert_true(loaded.active().sync is Synced)
  inspect(loaded.active().pending_steers.length(), content="0")
}

///|
test "an old-host Started without an id is settled by the exact start response" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="prompt-id"), },
    "prompt-id",
    "prompt",
  )
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="r-old-host",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    test_model().replace_conversation(conv),
  )
  assert_true(started.active().run is Open(run_id="r-old-host", ..))
  assert_true(started.active().pending_prompt is Some(_))
  let (_, responded) = update_dev(
    dispatch,
    StartResponded(
      session="desktop-test",
      submission_id="prompt-id",
      run_id="r-old-host",
      status="accepted",
      exit_code=0,
    ),
    started,
  )
  // The id-less Started could not settle the entry; the exact response can.
  assert_true(responded.active().run is Open(run_id="r-old-host", ..))
  inspect(responded.active().pending_steers.length(), content="0")
}

///|
test "a late accepted response settles run A without replacing open run B" {
  let dispatch = test_dispatch()
  guard second_run_started_before_first_response() is Some(result) else {
    fail("expected the second prompt to be starting")
  }
  let (second_started, second_submission) = result
  let (_, responded) = update_dev(
    dispatch,
    StartResponded(
      session="desktop-test",
      submission_id="first-start",
      run_id="r-first",
      status="accepted",
      exit_code=0,
    ),
    second_started,
  )
  assert_true(responded.active().run is Open(run_id="r-second", ..))
  assert_true(responded.active().last_run_id is Some("r-second"))
  guard responded.active().pending_prompt is Some(still_pending) else {
    fail("the late reply consumed the newer submission")
  }
  inspect(still_pending.submission_id, content=second_submission)
}

///|
test "a late failed response for durable run A cannot disturb open run B" {
  let dispatch = test_dispatch()
  guard second_run_started_before_first_response() is Some(result) else {
    fail("expected the second prompt to be starting")
  }
  let (second_started, second_submission) = result
  let (_, responded) = update_dev(
    dispatch,
    StartResponded(
      session="desktop-test",
      submission_id="first-start",
      run_id="r-first",
      status="failed",
      exit_code=1,
    ),
    second_started,
  )
  assert_true(responded.active().run is Open(run_id="r-second", ..))
  assert_true(responded.active().last_run_id is Some("r-second"))
  guard responded.active().pending_prompt is Some(still_pending) else {
    fail("the late reply consumed the newer submission")
  }
  inspect(still_pending.submission_id, content=second_submission)
}

///|
test "runs settled closes runs the host no longer has, sparing live and starting ones" {
  let dispatch = test_dispatch()
  // A run that ended while this client was away: its terminal event is
  // gone for good, so only the `agent.runs` reply can close it.
  let stale = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-stale",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Open(run_id="r9", stage=AtStep(Some(4))),
    turn: {
      ..empty_conversation(
        @interop.ChannelId::Local,
        "desktop-stale",
        @interop.ChannelId::Local.test_project(),
      ).turn,
      streaming_response: Some("mid-step"),
    },
  }
  // A send still in flight has no run id yet; its own `started` (or
  // failure) is coming and must be the one to settle it.
  let starting = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-starting",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Starting(submission_id="pending-start"),
  }
  let model = running_model()
    .replace_conversation(stale)
    .replace_conversation(starting)
  let (_, next) = update_dev(
    dispatch,
    RunsSettled(live=["r7"], frontier=[
      {
        session: "desktop-test",
        state: SnapshotOpen(run_id="r7"),
        initial_ids: [],
        pending_approval_id: None,
      },
      {
        session: "desktop-stale",
        state: SnapshotOpen(run_id="r9"),
        initial_ids: [],
        pending_approval_id: None,
      },
    ]),
    model,
  )
  // Run 7 is still in flight on the host: untouched.
  inspect(next.active().is_running(), content="true")
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-stale")
    is Some(settled) else {
    fail("expected the stale conversation")
  }
  inspect(settled.is_running(), content="false")
  assert_eq(settled.turn.streaming_response, None)
  guard settled.run is NoRun(ended=None) else {
    fail("expected the stale run to settle without a verdict")
  }
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-starting")
    is Some(sending) else {
    fail("expected the starting conversation")
  }
  assert_true(sending.run is Starting(..))
}

///|
test "reconnect runs snapshot settles only its captured Starting submission" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="pre-gap-start"), },
    "pre-gap-start",
    "maybe accepted",
  )
  let (_, bridged) = update_dev(
    dispatch,
    BridgeReady,
    test_model().replace_conversation(conv),
  )
  // The gap ended the entry: no receipt can cross it.
  inspect(bridged.active().pending_steers.length(), content="0")
  let (_, settled) = update_dev(
    dispatch,
    RunsSettled(
      live=[],
      frontier=bridged.run_snapshot_frontier(@interop.ChannelId::Local),
    ),
    bridged,
  )
  assert_true(settled.active().run is NoRun(ended=None))
}

///|
test "reconnect recovers a Finished notification dropped behind a slow page" {
  let dispatch = test_dispatch()
  // The host has already finished r7, but this page missed that one live
  // notification and still presents the run as open.
  let (_, bridged) = update_dev(dispatch, BridgeReady, running_model())
  let frontier = bridged.run_snapshot_frontier(@interop.ChannelId::Local)
  let (_, recovered) = update_dev(
    dispatch,
    RunsLoaded(
      runs=[],
      settled=[
        {
          run_id: "r7",
          session: "desktop-test",
          submission_id: None,
          status: "finished",
        },
      ],
      approvals=[],
      live=[],
      frontier~,
      connection_generation=bridged.dev().connection_generation,
    ),
    bridged,
  )
  assert_true(
    recovered.active().run is NoRun(ended=Some(RunFinished(Completed))),
  )
  assert_true(recovered.active().last_run_id is Some("r7"))
}

///|
test "an old empty runs snapshot cannot close a start sent after reconnect" {
  let dispatch = test_dispatch()
  let (_, bridged) = update_dev(dispatch, BridgeReady, test_model())
  // A reconnect clears the host-settings mirror; the refetch that follows
  // restores the saved key (the BYOK fixture is a ready app).
  let (_, ready) = update_dev(
    dispatch,
    HostSettings(
      Loaded(host_settings(provider="deepseek", has_deepseek_key=true)),
      connection_generation=None,
    ),
    bridged,
  )
  // A reconnect drops the worktree mirror and re-requests it; path-based work
  // stays parked until it answers, so restore it before sending.
  let ready = ready.with_dev(dev => {
    ..dev,
    worktrees: [@interop.ChannelId::Local.test_worktrees()],
  })
  let drafted = ready.replace_conversation({
    ..ready.active(),
    task: "new prompt",
  })
  let (_, sent) = update(dispatch, Send, drafted)
  assert_true(sent.active().run is Starting(..))
  // The submit is where the user's wait begins, so the elapsed span the tail
  // lane reports has to be established here — before any host round trip.
  assert_true(sent.active().run_started_ms is Some(_))
  let (_, stale_snapshot) = update_dev(
    dispatch,
    RunsSettled(live=[], frontier=[]),
    sent,
  )
  assert_true(stale_snapshot.active().run is Starting(..))
}

///|
test "an older start rejection cannot close the current start" {
  let dispatch = test_dispatch()
  let old = with_pending_prompt(
    test_conversation(),
    "older-start",
    "older prompt",
  )
  let current = with_pending_prompt(
    { ..old, run: Starting(submission_id="current-start"), },
    "current-start",
    "current prompt",
  )
  let (_, next) = update_dev(
    dispatch,
    StartRejected(
      session="desktop-test",
      submission_id="older-start",
      message="older start rejected",
    ),
    test_model().replace_conversation(current),
  )
  assert_true(next.active().run is Starting(submission_id="current-start"))
  guard next.active().pending_prompt is Some(pending) else {
    fail("the older rejection consumed the current submission")
  }
  inspect(pending.submission_id, content="current-start")
}

///|
test "a Started racing ahead of an older runs response stays open" {
  let dispatch = test_dispatch()
  let frontier = test_model().run_snapshot_frontier(@interop.ChannelId::Local)
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="r-after-snapshot",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some("foreign-new"),
    ),
    test_model(),
  )
  let (_, stale_snapshot) = update_dev(
    dispatch,
    RunsSettled(live=[], frontier~),
    started,
  )
  assert_true(
    stale_snapshot.active().run is Open(run_id="r-after-snapshot", ..),
  )
}

///|
test "a stale runs snapshot cannot replay a foreign run after BridgeReady" {
  let dispatch = test_dispatch()
  let (_, generation_one) = update_dev(dispatch, BridgeReady, test_model())
  let stale = RunsLoaded(
    runs=[
      {
        run_id: "old-run",
        session: "old-session",
        model: DsPro,
        max_steps: 1000,
        session_root: None,
        submission_id: None,
      },
    ],
    settled=[],
    approvals=[],
    live=["old-run"],
    frontier=generation_one.run_snapshot_frontier(@interop.ChannelId::Local),
    connection_generation=generation_one.dev().connection_generation,
  )
  let (_, generation_two) = update_dev(dispatch, BridgeReady, generation_one)
  // The current generation's empty answer wins first. The delayed older
  // answer must then be rejected whole, before replaying its Started row.
  let (_, current) = update_dev(
    dispatch,
    RunsLoaded(
      runs=[],
      settled=[],
      approvals=[],
      live=[],
      frontier=generation_two.run_snapshot_frontier(@interop.ChannelId::Local),
      connection_generation=generation_two.dev().connection_generation,
    ),
    generation_two,
  )
  let (_, once) = update_dev(dispatch, stale, current)
  let (_, twice) = update_dev(dispatch, stale, current)
  assert_true(
    once.find_conversation(@interop.ChannelId::Local, "old-session") is None,
  )
  assert_true(
    twice.find_conversation(@interop.ChannelId::Local, "old-session") is None,
  )
  inspect(once.dev().connection_generation, content="2")
  inspect(twice.dev().connection_generation, content="2")
}

///|
test "a settlement captured for an older Starting owner cannot close its successor" {
  let dispatch = test_dispatch()
  let old = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="old-owner"), },
    "old-owner",
    "old prompt",
  )
  let frontier = test_model()
    .replace_conversation(old)
    .run_snapshot_frontier(@interop.ChannelId::Local)
  let current = with_pending_prompt(
    { ..old, run: Starting(submission_id="new-owner"), },
    "new-owner",
    "new prompt",
  )
  let model = test_model().replace_conversation(current)
  let (_, unchanged) = update_dev(
    dispatch,
    RunsLoaded(
      runs=[],
      settled=[
        {
          run_id: "old-run",
          session: "desktop-test",
          submission_id: Some("old-owner"),
          status: "failed",
        },
      ],
      approvals=[],
      live=[],
      frontier~,
      connection_generation=model.dev().connection_generation,
    ),
    model,
  )
  assert_true(unchanged.active().run is Starting(submission_id="new-owner"))
  assert_true(unchanged.active().pending_prompt is Some(_))
}

///|
test "an older positive runs row cannot replace a newer Started" {
  let dispatch = test_dispatch()
  let model = running_model()
  let frontier = model.run_snapshot_frontier(@interop.ChannelId::Local)
  let (_, finished) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=None),
    model,
  )
  let (_, newer) = update_dev(
    dispatch,
    Started(
      run_id="r8",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    finished,
  )
  let (_, stale) = update_dev(
    dispatch,
    RunsLoaded(
      runs=[
        {
          run_id: "r7",
          session: "desktop-test",
          model: DsPro,
          max_steps: 1000,
          session_root: None,
          submission_id: None,
        },
      ],
      settled=[],
      approvals=[],
      live=["r7"],
      frontier~,
      connection_generation=0,
    ),
    newer,
  )
  assert_true(stale.active().run is Open(run_id="r8", ..))
  assert_true(stale.active().last_run_id is Some("r8"))
}

///|
test "an older positive runs row cannot resurrect a finished run" {
  let dispatch = test_dispatch()
  let model = running_model()
  let frontier = model.run_snapshot_frontier(@interop.ChannelId::Local)
  let (_, finished) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=None),
    model,
  )
  let (_, stale) = update_dev(
    dispatch,
    RunsLoaded(
      runs=[
        {
          run_id: "r7",
          session: "desktop-test",
          model: DsPro,
          max_steps: 1000,
          session_root: None,
          submission_id: None,
        },
      ],
      settled=[],
      approvals=[],
      live=["r7"],
      frontier~,
      connection_generation=0,
    ),
    finished,
  )
  assert_true(stale.active().run is NoRun(ended=Some(RunFinished(Completed))))
  assert_true(stale.active().last_run_id is Some("r7"))
}

///|
test "Finished after RunsSettled fills the last run outcome idempotently" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    last_run_id: Some("r7"),
  })
  let (_, settled) = update_dev(
    dispatch,
    RunsSettled(
      live=[],
      frontier=model.run_snapshot_frontier(@interop.ChannelId::Local),
    ),
    model,
  )
  assert_true(settled.active().run is NoRun(ended=None))
  let finish : DeviceMsg = Finished(run_id="r7", status="finished", answer=None)
  let (_, once) = update_dev(dispatch, finish, settled)
  let (_, twice) = update_dev(dispatch, finish, once)
  assert_true(once.active().run is NoRun(ended=Some(RunFinished(Completed))))
  assert_true(twice.active().run is NoRun(ended=Some(RunFinished(Completed))))
}

///|
test "a failed response after durable Finished cannot resurrect its prompt" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="fast-start"), },
    "fast-start",
    "fast prompt",
  )
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="r-fast",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some("fast-start"),
    ),
    test_model().replace_conversation(conv),
  )
  assert_true(started.active().pending_prompt is Some(_))
  let (_, finished) = update_dev(
    dispatch,
    Finished(run_id="r-fast", status="finished", answer=None),
    started,
  )
  assert_true(
    finished.active().run is NoRun(ended=Some(RunFinished(Completed))),
  )
  let (_, failed) = update_dev(
    dispatch,
    StartResponded(
      session="desktop-test",
      submission_id="fast-start",
      run_id="r-fast",
      status="failed",
      exit_code=1,
    ),
    finished,
  )
  assert_true(failed.active().run is NoRun(ended=Some(RunFinished(Completed))))
  inspect(failed.active().pending_steers.length(), content="0")
  let (_, empty) = update_dev(
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
    failed,
  )
  assert_true(empty.active().run is NoRun(ended=Some(RunFinished(Completed))))
  inspect(empty.active().pending_steers.length(), content="0")
}

///|
test "an accepted response consumes a fast-finished prompt without reopening" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    {
      ..test_conversation(),
      run: NoRun(ended=Some(RunFinished(Completed))),
      last_run_id: Some("r-fast"),
    },
    "fast-start",
    "fast prompt",
  )
  let (_, accepted) = update_dev(
    dispatch,
    StartResponded(
      session="desktop-test",
      submission_id="fast-start",
      run_id="r-fast",
      status="accepted",
      exit_code=0,
    ),
    test_model().replace_conversation(conv),
  )
  assert_true(
    accepted.active().run is NoRun(ended=Some(RunFinished(Completed))),
  )
  inspect(accepted.active().pending_steers.length(), content="0")
}

///|
test "concurrent conversations keep their streams apart" {
  let dispatch = test_dispatch()
  let second = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-second",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Open(run_id="r8", stage=Opened),
  }
  let model = running_model().replace_conversation(second)
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r8"), AssistantDelta("for B"), session=None),
    model,
  )
  // Run 8 belongs to the background conversation; the active one is untouched.
  assert_eq(next.active().turn.streaming_response, None)
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-second")
    is Some(bg) else {
    fail("expected the background conversation")
  }
  assert_eq(bg.turn.streaming_response, Some("for B"))
}

///|
test "a background run finishes without disturbing the conversation on screen" {
  let dispatch = test_dispatch()
  let second = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-second",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Open(run_id="r8", stage=Opened),
    messages: [
      {
        kind: User(content=Content([Text("background ask")])),
        ts: None,
        sequence: None,
      },
    ],
  }
  let model = running_model().replace_conversation(second)
  let (_, next) = update_dev(
    dispatch,
    Finished(run_id="r8", status="finished", answer=Some("done")),
    model,
  )
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-second")
    is Some(bg) else {
    fail("expected the background conversation")
  }
  inspect(bg.is_running(), content="false")
  assert_true(bg.run is NoRun(ended=Some(RunFinished(_))))
  // The conversation on screen is still running its own turn.
  inspect(next.active().is_running(), content="true")
  assert_true(next.display_status() is Running)
}

///|
test "a Stop reply for an already-ended run retires Stopping" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r7", stage=Cancelling),
  })
  let (_, next) = update_dev(dispatch, CancelNotOpen(run_id="r7"), model)
  assert_true(next.active().run is NoRun(ended=None))
  assert_eq(next.active().last_run_id, Some("r7"))
}

///|
test "a failed Stop becomes retryable instead of staying Stopping" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r7", stage=Cancelling),
  })
  let (_, next) = update_dev(
    dispatch,
    CancelFailed(run_id="r7", message="cancel transport failed"),
    model,
  )
  assert_true(next.active().run is Open(run_id="r7", stage=AtStep(None)))
  assert_true(
    next.notifications.any(item => {
      item.message.contains("cancel transport failed")
    }),
  )
}

///|
test "an old empty cancel reply cannot close a successor" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r8", stage=Opened),
  })
  let (_, next) = update_dev(dispatch, CancelNotOpen(run_id="r7"), model)
  assert_true(next.active().run is Open(run_id="r8", stage=Opened))
}
