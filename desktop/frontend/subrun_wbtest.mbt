///|
/// A lane belongs to its turn. The finish bracket that retires it is not
/// replayed, so a dropped connection or an engine that dies mid-sub-run must
/// not leave a pulsing lane behind.
test "a lane outlives neither its run nor a missing finish bracket" {
  let conv = { ..test_conversation(), run: Open(run_id="r1", stage=Opened), }
  let (_, opened) = apply_engine_event(
    conv,
    SubrunOpened(id="sr-1", kind="explore", label="where is X"),
    Some("r1"),
  )
  inspect(opened.visible_subruns().length(), content="1")
  // The run settles without a finish bracket ever arriving.
  let settled = { ..opened, run: NoRun(ended=Some(RunFailed)), }
  inspect(settled.visible_subruns().length(), content="0")
  // And the stranded lane does not reappear inside the NEXT turn.
  let next_turn = { ..settled, run: Open(run_id="r2", stage=Opened), }
  inspect(next_turn.visible_subruns().length(), content="0")
}

///|
/// A captured sub-run already has a durable tool brief, so closing its live
/// lane must not report a second completion. An abnormal close has no
/// successful tool brief to explain it, and no durable event of its own, so it
/// is reported to the user directly.
test "sub-run completion reports only abnormal terminal status" {
  let conv = { ..test_conversation(), run: Open(run_id="r1", stage=Opened), }
  let (_, opened) = apply_engine_event(
    conv,
    SubrunOpened(id="sr-1", kind="explore", label="where is X"),
    Some("r1"),
  )
  let (captured_report, closed) = apply_engine_event(
    opened,
    SubrunClosed(
      id="sr-1",
      status="captured",
      steps=37,
      tokens=12_449,
      unaccounted=None,
    ),
    Some("r1"),
  )
  assert_true(captured_report is None)
  inspect(closed.visible_subruns().length(), content="0")
  // The successful tool brief is the only completion row.
  inspect(closed.messages.length(), content="0")
  let (_, reopened) = apply_engine_event(
    closed,
    SubrunOpened(id="sr-2", kind="review", label="check the change"),
    Some("r1"),
  )
  let (failure_report, failed) = apply_engine_event(
    reopened,
    SubrunClosed(
      id="sr-2",
      status="failed",
      steps=4,
      tokens=901,
      unaccounted=None,
    ),
    Some("r1"),
  )
  inspect(failed.visible_subruns().length(), content="0")
  // The failed tool has no successful brief and no durable event of its own,
  // so the failure is reported as a toast rather than as a transcript row.
  assert_true(
    failure_report is Some("review sr-2: failed · 4 step(s) · 901 tok"),
  )
}

///|
test "a sub-run's progress refreshes the child transcript on screen" {
  // No follower broadcasts a child's commits, so this probe push is the only
  // thing that can move a transcript the reader opened mid-run.
  let page = subrun_page(active="desktop-test-sr-1")
  let (_, next) = update_dev(
    test_dispatch(),
    SubrunProgressed(
      id="sr-1",
      session="desktop-test-sr-1",
      steps=3,
      activity="shell",
    ),
    page,
  )
  // A fresh generation was minted for the read. `Cmd` is opaque, so this is
  // what separates an issued load from a conversation parked in `Reloading`
  // with nothing on the way to settle it.
  let generation = page.transcript_request_generation + 1
  assert_eq(next.transcript_request_generation, generation)
  guard subrun_child_of(next).sync
    is Reloading(generation=minted, reload_after_current=false, ..) else {
    fail("expected the viewed child to start a background reload")
  }
  assert_eq(minted, generation)
  // The reply that generation fences is accepted and adopted, proving the read
  // this started is one the model can actually settle.
  let (_, settled) = update_dev(
    test_dispatch(),
    SessionRefreshed(
      session="desktop-test-sr-1",
      items=[
        {
          kind: Assistant(
            reasoning=Some("child thought"),
            prose=None,
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: Some(5),
        },
      ],
      watermark=5,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation~,
    ),
    next,
  )
  let child = subrun_child_of(settled)
  assert_true(child.sync is Synced)
  assert_eq(child.watermark, 5)
  assert_eq(child.messages.length(), 1)
  // The parent's lane still advances: the two readers are independent.
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(parent) else {
    fail("expected the parent conversation to survive")
  }
  assert_eq(parent.turn.subruns[0].steps, 3)
  assert_eq(parent.turn.subruns[0].activity, "shell")
}

///|
test "a sub-run's progress leaves a child nobody is viewing alone" {
  // Reading the parent while its child works is the ordinary case; re-reading
  // a record no one is looking at is work with no reader.
  let (_, next) = update_dev(
    test_dispatch(),
    SubrunProgressed(
      id="sr-1",
      session="desktop-test-sr-1",
      steps=3,
      activity="shell",
    ),
    subrun_page(active="desktop-test"),
  )
  assert_true(subrun_child_of(next).sync is Synced)
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(parent) else {
    fail("expected the parent conversation to survive")
  }
  assert_eq(parent.turn.subruns[0].steps, 3)
}

///|
test "progress during an in-flight read is coalesced, not dropped" {
  // `begin_transcript_reload` would answer this with `None` and lose the
  // signal. The probe publishes only when the child ADVANCED, so a dropped
  // signal can be the last one ever sent — the transcript would then sit one
  // step short with nothing left to correct it.
  let (_, next) = update_dev(
    test_dispatch(),
    SubrunProgressed(
      id="sr-1",
      session="desktop-test-sr-1",
      steps=3,
      activity="shell",
    ),
    subrun_page(
      active="desktop-test-sr-1",
      child_sync=Reloading(
        generation=1,
        attempt=1,
        buffered=[],
        reload_after_current=false,
      ),
    ),
  )
  guard subrun_child_of(next).sync
    is Reloading(generation=1, reload_after_current=true, ..) else {
    fail("expected the in-flight read to be followed by one fresh generation")
  }
}

///|
test "a lane whose parent is gone still refreshes the child on screen" {
  // The lane update must not be a precondition for the refresh: they answer
  // to different conversations.
  let page = subrun_page(active="desktop-test-sr-1")
  let orphaned = {
    ..page,
    conversations: page.conversations.filter(conv => {
      conv.session_id != "desktop-test"
    }),
  }
  let (_, next) = update_dev(
    test_dispatch(),
    SubrunProgressed(
      id="sr-1",
      session="desktop-test-sr-1",
      steps=3,
      activity="shell",
    ),
    orphaned,
  )
  guard subrun_child_of(next).sync is Reloading(..) else {
    fail("expected the viewed child to reload without its parent")
  }
}

///|
test "a sub-run's finish refreshes the child transcript one last time" {
  // The host cancels the progress probe at the finish bracket without a final
  // poll, and the probe sleeps before it reads — so the child's last writes,
  // its report among them, arrive here or nowhere.
  let page = subrun_page(active="desktop-test-sr-1")
  let (_, next) = update_dev(
    test_dispatch(),
    Engine(
      Some("r7"),
      SubrunClosed(
        id="sr-1",
        status="captured",
        steps=7,
        tokens=30,
        unaccounted=None,
      ),
      session=None,
    ),
    page,
  )
  assert_eq(
    next.transcript_request_generation,
    page.transcript_request_generation + 1,
  )
  guard subrun_child_of(next).sync is Reloading(..) else {
    fail("expected the finish to catch the child transcript up")
  }
}

///|
/// A workflow's brackets record the run, and the sub-run brackets the host
/// synthesizes from its sidecar give the run its rows — the SAME bracket that
/// opens a child's lane. A sub-run outside the run's reserved block is an
/// ordinary child and touches no row.
test "a workflow's brackets and its children's brackets build the run's rows" {
  let conv = { ..test_conversation(), run: Open(run_id="r1", stage=Opened), }
  let (_, opened) = apply_engine_event(
    conv,
    WorkflowOpened(
      id="wf-5",
      journal="/store/run-wf-5/journal.jsonl",
      events="/store/run-wf-5/events.jsonl",
      first_child=5,
      child_count=32,
    ),
    Some("r1"),
  )
  inspect(opened.workflows.length(), content="1")
  let (_, child) = apply_engine_event(
    opened,
    SubrunOpened(id="sr-5", kind="explore", label="scout:x"),
    Some("r1"),
  )
  inspect(child.visible_subruns().length(), content="1")
  inspect(child.workflows[0].rows.length(), content="1")
  inspect(child.workflows[0].running(), content="1")
  let (_, other) = apply_engine_event(
    child,
    SubrunOpened(id="sr-2", kind="explore", label="elsewhere"),
    Some("r1"),
  )
  inspect(other.visible_subruns().length(), content="2")
  inspect(other.workflows[0].rows.length(), content="1")
  let (_, closed) = apply_engine_event(
    other,
    SubrunClosed(
      id="sr-5",
      status="captured",
      steps=12,
      tokens=3400,
      unaccounted=None,
    ),
    Some("r1"),
  )
  inspect(closed.workflows[0].running(), content="0")
  inspect(closed.workflows[0].rows[0].steps, content="12")
  // The lane is gone, as for any captured sub-run; the row stays.
  inspect(closed.visible_subruns().length(), content="1")
  let (_, done) = apply_engine_event(
    closed,
    WorkflowClosed(id="wf-5"),
    Some("r1"),
  )
  inspect(done.workflows[0].closed, content="true")
  inspect(done.workflows[0].rows.length(), content="1")
}

///|
/// A resolved call reaches the run through the parent session the entry
/// names. A conversation this page does not hold gets nothing: only a bracket
/// knows a run exists, and an entry is never a reason to invent one.
test "a workflow entry refines the parent conversation's run" {
  let base = running_conversation()
  let parent = {
    ..base,
    workflows: @workflow.opened(
      [],
      id="wf-5",
      session=base.session_id,
      first_child=5,
      child_count=32,
    ),
  }
  let model = test_model().replace_conversation(parent)
  let entry : @workflow.Entry = {
    workflow: "wf-5",
    session: base.session_id,
    child: "\{base.session_id}-sr-5",
    kind: "explore",
    label: "scout:x",
    phase: Some("survey"),
    status: "captured",
    steps: 12,
    prompt_tokens: 3000,
    completion_tokens: 400,
    cost_usd: Some(0.01),
    unaccounted: None,
    started_at: Some(1788535817640.0),
    finished_at: Some(1788535817648.0),
  }
  let (_, next) = update_dev(
    test_dispatch(),
    WorkflowEntryArrived(@interop.ChannelId::Local, entry),
    model,
  )
  guard next.find_conversation(@interop.ChannelId::Local, base.session_id)
    is Some(conv) else {
    fail("expected the parent conversation")
  }
  inspect(conv.workflows[0].rows.length(), content="1")
  inspect(conv.workflows[0].rows[0].ordinal, content="5")
  debug_inspect(conv.workflows[0].rows[0].phase, content="Some(\"survey\")")
  debug_inspect(conv.workflows[0].cost_usd(), content="Some(0.01)")
  let (_, same) = update_dev(
    test_dispatch(),
    WorkflowEntryArrived(@interop.ChannelId::Local, {
      ..entry,
      session: "elsewhere",
    }),
    next,
  )
  assert_true(
    same.find_conversation(@interop.ChannelId::Local, "elsewhere") is None,
  )
  guard same.find_conversation(@interop.ChannelId::Local, base.session_id)
    is Some(untouched) else {
    fail("expected the parent conversation")
  }
  inspect(untouched.workflows[0].rows.length(), content="1")
}
