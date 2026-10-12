///|
/// Run A ended with one steer receipt still in flight, then run B started.
fn second_run_started_before_first_steer_receipt() -> Model? {
  let dispatch = test_dispatch()
  let first = with_pending_steers(running_conversation(), ["late steer"])
  let (_, first_finished) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=None),
    running_model().replace_conversation(first),
  )
  // A second local run is admitted only after the prior durable terminal has
  // reconciled. The old steer receipt may still trail that boundary.
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
  guard reconciled.active_conversation() is Some(idle) else { return None }
  let drafted = reconciled.replace_conversation({
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
      run_id="r8",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=Some(second_submission),
    ),
    sending,
  )
  Some(second_started)
}

///|
test "send while running queues a steer instead of a prompt" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    task: "focus on the tests",
  })
  let (_, once) = update(dispatch, Send, model)
  let (_, twice) = update(dispatch, Send, model)
  inspect(once.active().task, content="")
  inspect(once.active().pending_steers.length(), content="1")
  assert_eq(once.active().pending_steers[0].content, "focus on the tests")
  // The steer is pending, not part of the transcript yet.
  inspect(once.active().messages.length(), content="0")
  inspect(once.active().is_running(), content="true")
  inspect(twice.active().pending_steers.length(), content="1")
  inspect(
    twice.active().pending_steers[0].content,
    content="focus on the tests",
  )
}

///|
test "a cancelling turn cannot be steered; the text stays in the composer" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation({
    ..running_conversation(),
    run: Open(run_id="r7", stage=Cancelling),
    task: "too late",
  })
  let (_, next) = update(dispatch, Send, model)
  inspect(next.active().task, content="too late")
  inspect(next.active().pending_steers.length(), content="0")
}

///|
test "steer_applied only settles pending UI until its commit" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["go left"]),
  )
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerApplied(
        content=Content([Text("go left")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    model,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().messages.length(), content="0")
}

///|
test "a legacy text-only steer receipt cannot claim local ownership" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["go left"]),
  )
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerApplied(content=Content([Text("go left")]), submission_id=None),
      session=None,
    ),
    model,
  )
  inspect(next.active().pending_steers.length(), content="1")
}

///|
test "a canonical user commit never settles a local steer" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["go left"]),
  )
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("go left")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  inspect(committed.active().messages.length(), content="1")
  inspect(committed.active().pending_steers.length(), content="1")
}

///|
test "a snapshot never settles a local steer by text" {
  let dispatch = test_dispatch()
  let conv = with_pending_steers(
    {
      ..running_conversation(),
      messages: [
        {
          kind: User(content=Content([Text("same")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark: 1,
      sync: test_reloading([]),
    },
    ["same"],
  )
  let model = running_model().replace_conversation(conv)
  let (_, loaded) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: User(content=Content([Text("same")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=1,
      generation=1,
    ),
    model,
  )
  inspect(loaded.active().pending_steers.length(), content="1")
}

///|
test "steer_dropped settles the pending steer with a visible notice" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["go left"]),
  )
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerDropped(
        content=Content([Text("go left")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    model,
  )
  inspect(next.active().pending_steers.length(), content="0")
  inspect(next.active().task, content="go left")
  inspect(next.notifications.length(), content="1")
  assert_true(next.notifications[0].message.contains("back in the composer"))
}

///|
test "an identical-text settle removes exactly one pending entry" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["again", "again"]),
  )
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerApplied(
        content=Content([Text("again")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    model,
  )
  inspect(next.active().pending_steers.length(), content="1")
  assert_eq(next.active().pending_steers[0].content, "again")
  inspect(next.active().pending_steers[0].submission_id, content="test-steer-1")
}

///|
test "a late exact applied receipt retracts a run-end unconfirmed notice" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["lost"]),
  )
  let (_, finished) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("")),
    model,
  )
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerApplied(
        content=Content([Text("lost")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    finished,
  )
  inspect(next.active().pending_steers.length(), content="0")
}

///|
test "a trailing applied receipt for run A settles after run B Started" {
  let dispatch = test_dispatch()
  guard second_run_started_before_first_steer_receipt() is Some(started) else {
    fail("expected the second prompt to be starting")
  }
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerApplied(
        content=Content([Text("late steer")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    started,
  )
  assert_true(next.active().run is Open(run_id="r8", ..))
  assert_true(next.active().last_run_id is Some("r8"))
  inspect(next.active().pending_steers.length(), content="0")
  assert_true(next.active().pending_prompt is Some(_))
}

///|
test "a trailing dropped receipt for run A cannot close run B" {
  let dispatch = test_dispatch()
  guard second_run_started_before_first_steer_receipt() is Some(started) else {
    fail("expected the second prompt to be starting")
  }
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerDropped(
        content=Content([Text("late steer")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    started,
  )
  // Run A ended when B replaced it, taking A's pending steer with it, so the
  // trailing receipt has nothing left to settle. What it must not do is
  // disturb B.
  assert_true(next.active().run is Open(run_id="r8", ..))
  assert_true(next.active().last_run_id is Some("r8"))
  inspect(next.active().pending_steers.length(), content="0")
  assert_true(next.active().pending_prompt is Some(_))
  inspect(next.active().task, content="")
}

///|
test "a reloading transcript does not hold up a steer" {
  let dispatch = test_dispatch()
  // The record is what a turn writes, not a precondition for submitting to
  // one. Reading it is the transcript's problem; the engine takes the text
  // either way, and the record is where it shows up.
  let conv = {
    ..running_conversation(),
    task: "steer while reloading",
    sync: test_reloading([]),
  }
  let model = running_model().replace_conversation(conv)
  let (_, next) = update(dispatch, Send, model)
  inspect(next.active().task, content="")
  inspect(next.active().pending_steers.length(), content="1")
}

///|
test "a trailing applied receipt settles after an empty runs snapshot" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["late applied"]),
  )
  let frontier = model.run_snapshot_frontier(@interop.ChannelId::Local)
  let (_, settled) = update_dev(
    dispatch,
    RunsSettled(live=[], frontier~),
    model,
  )
  let (_, applied) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerApplied(
        content=Content([Text("late applied")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    settled,
  )
  inspect(applied.active().pending_steers.length(), content="0")
}

///|
test "a trailing dropped receipt after an empty runs snapshot changes nothing" {
  let dispatch = test_dispatch()
  let model = running_model().replace_conversation(
    with_pending_steers(running_conversation(), ["late dropped"]),
  )
  let frontier = model.run_snapshot_frontier(@interop.ChannelId::Local)
  let (_, settled) = update_dev(
    dispatch,
    RunsSettled(live=[], frontier~),
    model,
  )
  let (_, dropped) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      SteerDropped(
        content=Content([Text("late dropped")]),
        submission_id=Some("test-steer-0"),
      ),
      session=None,
    ),
    settled,
  )
  // The snapshot already ended the run and its pending steer; a receipt that
  // trails it owns nothing.
  inspect(dropped.active().pending_steers.length(), content="0")
  inspect(dropped.active().task, content="")
}
