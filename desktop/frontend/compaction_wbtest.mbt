///|
/// A prompt submitted mid-compaction must not start: the serve engine would
/// queue it behind the compaction, out of Stop's reach. The draft stays put.
test "a prompt submitted during compaction stays in the composer" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Compacting,
    task: "do the thing",
  })
  let (_, next) = update(dispatch, Send, model)
  inspect(next.active().task, content="do the thing")
  inspect(next.active().messages.length(), content="0")
}

///|
/// A `/compact` sent mid-turn queues behind the open run in the engine. The
/// composer must say so immediately, swallow a duplicate, and keep the send
/// gate held through the gap between the turn's end and the engine's
/// compaction_started.
test "a mid-turn /compact stays visibly queued until compaction starts" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..running_conversation(),
    last_run_id: Some("r7"),
  })
  let (_, queued) = run_slash_command(dispatch, model, "compact")
  assert_true(queued.active().compaction is Queued)
  // One compaction at a time: the repeat is swallowed, not re-sent.
  let (_, again) = run_slash_command(dispatch, queued, "compact")
  assert_true(again.active().compaction is Queued)
  // The turn ends before compaction_started arrives; a prompt sent into
  // that gap would queue behind the compaction, out of Stop's reach.
  let (_, ended) = update_dev(
    dispatch,
    Finished(run_id="r7", status="completed", answer=None),
    again,
  )
  assert_true(ended.active().compaction is Queued)
  let drafted = ended.replace_conversation({
    ..ended.active(),
    task: "next prompt",
  })
  let (_, held) = update(dispatch, Send, drafted)
  inspect(held.active().task, content="next prompt")
  // The engine reaches the queued compaction: queued flips into compacting.
  let (_, started) = update_dev(
    dispatch,
    Engine(Some("r7"), CompactionStarted, session=None),
    held,
  )
  assert_true(started.active().compaction is Compacting)
}

///|
/// An idle `/compact` has no engine acknowledgment yet — the host may still
/// be spawning a serve engine for it (a resumed conversation compacted
/// before its first prompt) — but the request must hold the send gate
/// immediately: a prompt sent into that window would be consumed and
/// rejected by the host instead of held in the composer.
test "an idle /compact holds the send gate until the engine confirms" {
  let dispatch = test_dispatch()
  let (_, requested) = run_slash_command(dispatch, test_model(), "compact")
  assert_true(requested.active().compaction is Requested)
  // A repeat while the request is in flight is swallowed, not re-sent.
  let (_, again) = run_slash_command(dispatch, requested, "compact")
  assert_true(again.active().compaction is Requested)
  // A draft sent during the spawn/write window stays in the composer.
  let drafted = again.replace_conversation({
    ..again.active(),
    task: "next prompt",
  })
  let (_, held) = update(dispatch, Send, drafted)
  inspect(held.active().task, content="next prompt")
  inspect(held.active().messages.length(), content="0")
  // The engine confirms; the session stamp routes it (no run id exists yet).
  let (_, started) = update_dev(
    dispatch,
    Engine(None, CompactionStarted, session=Some("desktop-test")),
    held,
  )
  assert_true(started.active().compaction is Compacting)
}

///|
/// Rabbita purity: the automatic-checkpoint semantic event is lifecycle-only;
/// its Summary card comes from the durable commit.
test "update is pure: automatic checkpoint waits for its commit" {
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
    Engine(Some("r7"), AutoCompactionFinished("checkpoint recap"), session=None),
    model,
  )
  let (_, twice) = update_dev(
    dispatch,
    Engine(Some("r7"), AutoCompactionFinished("checkpoint recap"), session=None),
    model,
  )
  assert_eq(once.active().turn.streaming_response, Some("partial"))
  assert_eq(twice.active().turn.streaming_response, Some("partial"))
  assert_true(
    once.active().compaction is NotCompacting &&
    twice.active().compaction is NotCompacting,
  )
}

///|
/// Rabbita purity: context-yield guidance is a deterministic model update.
/// The raw stream event clears partial streams but does not close the run;
/// the host's following Finished message owns that transition.
test "update is pure: context yield waits for its commit" {
  let dispatch = test_dispatch()
  let answer = "[context ceiling] continue in a new turn"
  let model = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("partial"),
    },
  })
  let (_, once) = update_dev(
    dispatch,
    Engine(Some("r7"), ContextYield(answer), session=None),
    model,
  )
  let (_, twice) = update_dev(
    dispatch,
    Engine(Some("r7"), ContextYield(answer), session=None),
    model,
  )
  assert_eq(once.active().turn.streaming_response, None)
  assert_eq(twice.active().turn.streaming_response, None)
  assert_true(once.active().is_running() && twice.active().is_running())
}

///|
/// The successful ceiling path re-opens Send without synthesizing durable
/// transcript items. Its Summary and guidance arrive through commits.
test "context yield settles after its automatic checkpoint" {
  let dispatch = test_dispatch()
  let answer = "[context ceiling] continue in a new turn"
  let (_, checkpointed) = update_dev(
    dispatch,
    Engine(Some("r7"), AutoCompactionFinished("checkpoint recap"), session=None),
    running_model(),
  )
  let (_, yielded) = update_dev(
    dispatch,
    Engine(Some("r7"), ContextYield(answer), session=None),
    checkpointed,
  )
  assert_true(yielded.active().is_running())
  let (_, settled) = update_dev(
    dispatch,
    Finished(run_id="r7", status="context_yield", answer=Some(answer)),
    yielded,
  )
  assert_true(settled.active().compaction is NotCompacting)
  assert_false(settled.active().is_running())
  guard settled.display_status() is Finished(outcome) else {
    fail("expected a finished status")
  }
  assert_true(outcome is ContextYield)
  inspect(outcome.label(), content="Context limit reached")
  assert_true(settled.display_status().kind() is Warn)
}

///|
/// Compaction completion settles lifecycle state; its Summary is commit-only.
test "compaction_finished waits for its durable summary" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Compacting,
    last_run_id: Some("r7"),
  })
  let (_, next) = update_dev(
    dispatch,
    Engine(
      Some("r7"),
      CompactionFinished("earlier turns compacted"),
      session=None,
    ),
    model,
  )
  assert_true(next.active().compaction is NotCompacting)
}

///|
/// A conversation resumed and compacted before its first prompt of this
/// app-lifetime has no run id anywhere — the spawned engine stamps run 0 and
/// the conversation's `last_run_id` is still `None` — so compaction events
/// must route by the session the host stamps on them.
test "compaction events route by session when no run id matches" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    last_run_id: None,
  })
  let (_, started) = update_dev(
    dispatch,
    Engine(None, CompactionStarted, session=Some("desktop-test")),
    model,
  )
  assert_true(started.active().compaction is Compacting)
  let (_, next) = update_dev(
    dispatch,
    Engine(
      None,
      CompactionFinished("earlier turns compacted"),
      session=Some("desktop-test"),
    ),
    started,
  )
  assert_true(next.active().compaction is NotCompacting)
}

///|
/// The host synthesizes compaction_failed when the engine dies with a
/// compaction still queued behind the dead turn; that terminal event must
/// settle the queued notice like any other compaction failure.
test "compaction_failed settles a still-queued compaction" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Queued,
    last_run_id: Some("r7"),
  })
  let (_, next) = update_dev(
    dispatch,
    Engine(Some("r7"), CompactionFailed("engine exited"), session=None),
    model,
  )
  assert_true(next.active().compaction is NotCompacting)
  inspect(next.notifications.length(), content="1")
}

///|
/// A rejected compact request (no engine, host error) never produces
/// compaction events, so the rejection itself clears the queued notice and
/// reports the error.
test "CompactRejected clears the queued notice and reports the error" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    compaction: Queued,
  })
  let (_, next) = update_dev(
    dispatch,
    CompactRejected(session="desktop-test", message="no engine"),
    model,
  )
  assert_true(next.active().compaction is NotCompacting)
  inspect(next.notifications.length(), content="1")
  inspect(next.notifications[0].message, content="no engine")
}
