///|
test "an approval notification click opens its local conversation" {
  let dispatch = test_dispatch()
  let remote : @interop.ChannelId = Remote("d-remote")
  let home = running_model()
  let model = {
    ..home,
    devices: [
      home.devices[0],
      { ..empty_device_state(remote), bridge: Connected, },
    ],
    focused: remote,
    active_session: "",
  }
  let (_, opened) = update(dispatch, NotificationClicked(run_id="r7"), model)
  assert_true(opened.focused is Local)
  assert_eq(opened.active_session, "desktop-test")
}

///|
test "new chat keeps the model intact until the rotation lands" {
  let dispatch = test_dispatch()
  let model = {
    ..running_model(),
    loading_conversation: Some({ channel: Local, session: "desktop-stale", }),
  }
  let (_, next) = update(dispatch, NewChat, model)
  inspect(next.active().is_running(), content="true")
  assert_true(next.loading_conversation is None)
}

///|
test "generated session ids include a random suffix" {
  let id = generated_session_id()
  let parts = [..id.split("-")]
  inspect(parts.length(), content="5")
  inspect(parts[0], content="desktop")
  inspect(parts[1].length(), content="8")
  inspect(parts[2].length(), content="6")
  inspect(parts[3].length(), content="3")
  inspect(parts[4].length(), content="9")
  let _ = @string.parse_int(parts[1]) catch {
    _ => fail("expected numeric date")
  }
  let _ = @string.parse_int(parts[2]) catch {
    _ => fail("expected numeric time")
  }
  let _ = @string.parse_int(parts[3]) catch {
    _ => fail("expected numeric millis")
  }
  let _ = @string.parse_int(parts[4]) catch {
    _ => fail("expected numeric salt")
  }
}

///|
test "session rotation activates a fresh conversation, keeping the old one" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..running_conversation(),
    messages: [
      { kind: User(content=Content([Text("hi")])), ts: None, sequence: None, },
    ],
  })
  let (_, next) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "desktop-fresh", }),
    model,
  )
  inspect(next.active_session, content="desktop-fresh")
  inspect(next.active().messages.length(), content="0")
  inspect(next.active().turn.usage_tokens, content="0")
  assert_true(next.display_status() is Ready)
  // The previous conversation keeps running in the background.
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(old) else {
    fail("expected the old conversation to survive")
  }
  inspect(old.is_running(), content="true")
  inspect(old.messages.length(), content="1")
}

///|
test "session rotation prunes abandoned empty conversations" {
  let dispatch = test_dispatch()
  let (_, first) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "desktop-a", }),
    test_model(),
  )
  let (_, second) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "desktop-b", }),
    first,
  )
  // "desktop-test" and "desktop-a" had no transcript, no draft, no run.
  inspect(second.conversations.length(), content="1")
  inspect(second.active_session, content="desktop-b")
}

///|
test "a delayed rotation cannot steal focus from another channel" {
  let dispatch = test_dispatch()
  let remote : @interop.ChannelId = Remote("d-remote")
  let model = {
    ..test_model(),
    devices: [
      { ..empty_device_state(@interop.ChannelId::Local), bridge: Connected, },
      { ..empty_device_state(remote), bridge: Connected, },
    ],
  }
  let (_, next) = update(
    dispatch,
    SessionRotated({ channel: remote, session: "remote-late", }),
    model,
  )
  assert_true(next.focused is Local)
  inspect(next.active_session, content="desktop-test")
  assert_true(next.find_conversation(remote, "remote-late") is None)
}

///|
test "open session is a no-op for the current session" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-test"),
    test_model(),
  )
  inspect(next.active_session, content="desktop-test")
  inspect(next.conversations.length(), content="1")
}

///|
test "a sub-run child opens through its parent before the store lists it" {
  // The Workflows tab offers a click into a child the sidebar has not listed
  // yet (the inventory refreshes at connect, archive and unarchive, not when
  // a child appears mid-run). The child's session lives in its parent's
  // store, so the parent's placement is its own.
  let dispatch = test_dispatch()
  let model = test_model()
  assert_true(
    model.session_project(@interop.ChannelId::Local, "desktop-test-sr-2")
    is Some(_),
  )
  let (_, next) = update(dispatch, OpenSessionHere("desktop-test-sr-2"), model)
  // The click selects the child and starts its first load; the view switches
  // when the snapshot lands, as for any session opened from the sidebar.
  guard next.selected_conversation is Some(selection) else {
    fail("expected the child to be selected")
  }
  inspect(selection.session, content="desktop-test-sr-2")
  assert_eq(selection.workspace, @interop.ChannelId::Local.test_project())
  assert_true(
    next.loading_conversation
    is Some({ channel: Local, session: "desktop-test-sr-2", }),
  )
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-test-sr-2")
    is Some(child) else {
    fail("expected the child conversation to exist, loading")
  }
  assert_true(child.sync is Reloading(..))
  inspect(
    next.transcript_request_generation,
    content="\{model.transcript_request_generation + 1}",
  )
  // A child of a parent this page knows nothing about is still unplaceable.
  let (_, same) = update(dispatch, OpenSessionHere("elsewhere-sr-2"), model)
  inspect(same.active_session, content="desktop-test")
}

///|
test "open session keeps live state on screen while re-reading the store" {
  let dispatch = test_dispatch()
  let background = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-bg",
      @interop.ChannelId::Local.test_project(),
    ),
    run: Open(run_id="r9", stage=Opened),
    messages: [
      {
        kind: User(content=Content([Text("background task")])),
        ts: None,
        sequence: None,
      },
    ],
    turn: {
      ..empty_conversation(
        @interop.ChannelId::Local,
        "desktop-bg",
        @interop.ChannelId::Local.test_project(),
      ).turn,
      streaming_response: Some("mid-stream"),
    },
  }
  let model = running_model().replace_conversation(background)
  let (_, once) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-bg"),
    model,
  )
  let (_, twice) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-bg"),
    model,
  )
  inspect(once.active_session, content="desktop-bg")
  // The live state stays on screen; the store re-read happens behind it
  // (this client may have been absent for part of this conversation).
  assert_eq(once.active().turn.streaming_response, Some("mid-stream"))
  inspect(once.active().is_running(), content="true")
  assert_true(
    once.loading_conversation
    is Some({ channel: Local, session: "desktop-bg", }),
  )
  // The previous conversation is still running in the background.
  guard once.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(old) else {
    fail("expected the old conversation to survive")
  }
  inspect(old.is_running(), content="true")
  inspect(twice.active_session, content="desktop-bg")
}

///|
test "open session tracks the latest load and ignores stale replies" {
  let dispatch = test_dispatch()
  let (_, loading_a) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-a"),
    test_model().with_listed(["desktop-a", "desktop-b"]),
  )
  inspect(loading_a.active_session, content="desktop-test")
  assert_true(
    loading_a.loading_conversation
    is Some({ channel: Local, session: "desktop-a", }),
  )
  let (_, loading_b) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-b"),
    loading_a,
  )
  assert_true(
    loading_b.loading_conversation
    is Some({ channel: Local, session: "desktop-b", }),
  )
  let a_items : Array[@transcript.TranscriptItem] = [
    {
      kind: User(content=Content([Text("old selection")])),
      ts: None,
      sequence: None,
    },
  ]
  let (_, after_a) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-a",
      items=a_items,
      watermark=0,
      generation=1,
    ),
    loading_b,
  )
  inspect(after_a.active_session, content="desktop-test")
  assert_true(
    after_a.loading_conversation
    is Some({ channel: Local, session: "desktop-b", }),
  )
  let b_items : Array[@transcript.TranscriptItem] = [
    {
      kind: User(content=Content([Text("latest selection")])),
      ts: None,
      sequence: None,
    },
  ]
  let (_, after_b) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-b",
      items=b_items,
      watermark=0,
      generation=2,
    ),
    after_a,
  )
  inspect(after_b.active_session, content="desktop-b")
  assert_true(after_b.loading_conversation is None)
  assert_eq(after_b.active().messages[0].text(), Some("latest selection"))
}

///|
test "a restored session keeps the placement its listing named" {
  let dispatch = test_dispatch()
  let session = "desktop-restored"
  let (_, listed) = update(
    dispatch,
    sessions_loaded([
      {
        id: session,
        title: Some("restored"),
        workspace: @interop.ChannelId::Local.test_project(),
        workspace_name: "work",
        updated_at_ms: None,
      },
    ]),
    test_model(),
  )
  let (_, loading) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, session),
    listed,
  )
  guard loading.find_conversation(@interop.ChannelId::Local, session)
    is Some(before) else {
    fail("conversation was not materialized for loading")
  }
  assert_true(
    loading.conversation_root(before) is Some(root) && root.path == "/work",
  )
  let (_, restored) = update_dev(
    dispatch,
    SessionLoaded(
      session~,
      items=[],
      watermark=0,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation=1,
    ),
    loading,
  )
  assert_eq(restored.active_session, session)
  // Placement stays stable across transcript restoration: it follows the
  // project the listing named, not anything the transcript carries.
  assert_true(restored.active().workspace is Project(..))
  assert_true(
    restored.conversation_root(restored.active()) is Some(root) &&
    root.path == "/work",
  )
  assert_true(
    file_ctx(restored).placement is Some(placement) &&
    placement.checkout_root() is Some(root) &&
    root.path == "/work",
  )
}

///|
test "same-id session loads are fenced by channel owner" {
  let dispatch = test_dispatch()
  let remote : @interop.ChannelId = Remote("d-remote")
  let local_conv = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "shared",
      @interop.ChannelId::Local.test_project(),
    ),
    messages: [
      {
        kind: User(content=Content([Text("local")])),
        ts: None,
        sequence: None,
      },
    ],
  }
  let remote_conv = {
    ..empty_conversation(remote, "shared", remote.test_project()),
    messages: [
      {
        kind: User(content=Content([Text("remote")])),
        ts: None,
        sequence: None,
      },
    ],
  }
  let model = {
    ..test_model(),
    devices: [
      { ..empty_device_state(@interop.ChannelId::Local), bridge: Connected, },
      { ..empty_device_state(remote), bridge: Connected, },
    ],
    active_session: "shared",
    conversations: [local_conv, remote_conv],
  }
  let (_, loading_remote) = update(
    dispatch,
    OpenSession(remote, "shared"),
    model,
  )
  let (_, loading_local) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "shared"),
    loading_remote,
  )
  assert_true(
    loading_local.loading_conversation
    is Some({ channel: Local, session: "shared", }),
  )
  let (_, remote_reply) = update(
    dispatch,
    FromDevice(
      remote,
      SessionLoaded(
        goal=None,
        goal_markers=[],
        prediction=None,
        session="shared",
        items=[
          {
            kind: Assistant(
              reasoning=None,
              prose=Some("remote loaded"),
              calls=[],
              replay=false,
              finished=false,
            ),
            ts: None,
            sequence: None,
          },
        ],
        watermark=1,
        generation=1,
      ),
    ),
    loading_local,
  )
  assert_true(remote_reply.focused is Local)
  assert_eq(remote_reply.active().messages[0].text(), Some("local"))
  assert_true(
    remote_reply.loading_conversation
    is Some({ channel: Local, session: "shared", }),
  )
  guard remote_reply.find_conversation(remote, "shared") is Some(loaded) else {
    fail("remote conversation disappeared")
  }
  assert_eq(loaded.messages[0].text(), Some("remote loaded"))
}

///|
test "reselecting a synced active session reloads idle external writes" {
  let dispatch = test_dispatch()
  let model = test_model().with_dev(dev => {
    ..dev,
    sessions: [
      {
        id: "desktop-test",
        title: Some(""),
        workspace: @interop.ChannelId::Local.test_project(),
        workspace_name: "",
        updated_at_ms: None,
      },
    ],
  })
  let (_, reloading) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-test"),
    model,
  )
  assert_true(
    reloading.loading_conversation
    is Some({ channel: Local, session: "desktop-test", }),
  )
  guard reloading.active().sync is Reloading(generation=1, attempt=1, ..) else {
    fail("expected active reselect to catch up")
  }
  let (_, still_single_flight) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-test"),
    reloading,
  )
  inspect(still_single_flight.transcript_request_generation, content="1")
  guard still_single_flight.active().sync
    is Reloading(generation=1, attempt=1, ..) else {
    fail("active reselect duplicated an in-flight request")
  }
  let (_, loaded) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("written elsewhere"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: None,
        },
      ],
      watermark=1,
      generation=1,
    ),
    still_single_flight,
  )
  inspect(loaded.active().messages.length(), content="1")
  assert_eq(loaded.active().messages[0].text(), Some("written elsewhere"))
  inspect(loaded.active().watermark, content="1")
  assert_true(loaded.active().sync is Synced)
}

///|
test "returning to a fresh active chat does not load a missing session" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      task: "unsent draft",
    }),
    screen: Skills,
  }
  let (_, next) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-test"),
    model,
  )
  assert_true(next.screen is Chat)
  assert_true(next.loading_conversation is None)
  inspect(next.transcript_request_generation, content="0")
  assert_true(next.active().sync is Synced)
  inspect(next.active().task, content="unsent draft")
}

///|
test "pruning and reopening cannot reuse a transcript request token" {
  let dispatch = test_dispatch()
  let (_, opening) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-pruned"),
    test_model().with_listed(["desktop-pruned"]),
  )
  guard opening.find_conversation(@interop.ChannelId::Local, "desktop-pruned")
    is Some(first) &&
    first.sync is Reloading(generation=1, ..) else {
    fail("expected the original request")
  }
  let pruned = opening.activate(
    @interop.ChannelId::Local,
    "desktop-other",
    @interop.ChannelId::Local.test_project(),
  )
  assert_true(
    pruned.find_conversation(@interop.ChannelId::Local, "desktop-pruned")
    is None,
  )
  let (_, reopened) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-pruned"),
    pruned,
  )
  guard reopened.find_conversation(@interop.ChannelId::Local, "desktop-pruned")
    is Some(second) &&
    second.sync is Reloading(generation=2, ..) else {
    fail("reopened conversation reused its old request token")
  }
  let (_, stale) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-pruned",
      items=[
        {
          kind: User(content=Content([Text("late old snapshot")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=9,
      generation=1,
    ),
    reopened,
  )
  assert_true(
    stale.loading_conversation
    is Some({ channel: Local, session: "desktop-pruned", }),
  )
  guard stale.find_conversation(@interop.ChannelId::Local, "desktop-pruned")
    is Some(current) &&
    current.sync is Reloading(generation=2, ..) else {
    fail("late reply changed the reopened conversation")
  }
  inspect(current.messages.length(), content="0")
  inspect(current.watermark, content="0")
  let (_, fresh) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-pruned",
      items=[
        {
          kind: User(content=Content([Text("fresh snapshot")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=1,
      generation=2,
    ),
    stale,
  )
  inspect(fresh.active_session, content="desktop-pruned")
  assert_eq(fresh.active().messages[0].text(), Some("fresh snapshot"))
}

///|
test "archive removal and reopening cannot reuse a transcript request token" {
  let dispatch = test_dispatch()
  let (_, opening) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-archived"),
    test_model().with_listed(["desktop-archived"]),
  )
  let (_, archived) = update(
    dispatch,
    archived_loaded([archived_item("desktop-archived")]),
    opening,
  )
  assert_true(
    archived.find_conversation(@interop.ChannelId::Local, "desktop-archived")
    is None,
  )
  let (_, restored) = update(dispatch, archived_loaded([]), archived)
  // Archiving pruned the live row; the list refresh that follows an
  // unarchive is what puts it back, and the row is what names its store.
  let (_, reopened) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-archived"),
    restored.with_listed(["desktop-archived"]),
  )
  guard reopened.find_conversation(
      @interop.ChannelId::Local,
      "desktop-archived",
    )
    is Some(current) &&
    current.sync is Reloading(generation=2, ..) else {
    fail("archive removal allowed a request token to be reused")
  }
  let (_, stale) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-archived",
      items=[
        {
          kind: User(content=Content([Text("late archived snapshot")])),
          ts: None,
          sequence: None,
        },
      ],
      watermark=4,
      generation=1,
    ),
    reopened,
  )
  guard stale.find_conversation(@interop.ChannelId::Local, "desktop-archived")
    is Some(unchanged) &&
    unchanged.sync is Reloading(generation=2, ..) else {
    fail("late pre-archive reply changed the reopened conversation")
  }
  inspect(unchanged.messages.length(), content="0")
  inspect(unchanged.watermark, content="0")
}

///|
test "an abandoned session load retries silently" {
  let dispatch = test_dispatch()
  let (_, loading) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-a"),
    test_model().with_listed(["desktop-a"]),
  )
  let (_, abandoned) = update(dispatch, NewChat, loading)
  let (_, next) = update_dev(
    dispatch,
    SessionLoadFailed(
      session="desktop-a",
      message="failed to load session desktop-a",
      generation=1,
    ),
    abandoned,
  )
  assert_true(next.loading_conversation is None)
  inspect(next.active().messages.length(), content="0")
  inspect(next.notifications.length(), content="0")
}

///|
test "a foreground load preserves state through retries and reports exhaustion" {
  let dispatch = test_dispatch()
  let (_, loading) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-a"),
    test_model().with_listed(["desktop-a"]),
  )
  let failure = SessionLoadFailed(
    session="desktop-a",
    message="failed to load session desktop-a: no such file",
    generation=1,
  )
  let (_, retrying2) = update_dev(dispatch, failure, loading)
  assert_true(
    retrying2.loading_conversation
    is Some({ channel: Local, session: "desktop-a", }),
  )
  inspect(retrying2.notifications.length(), content="0")
  guard retrying2.find_conversation(@interop.ChannelId::Local, "desktop-a")
    is Some(conv2) &&
    conv2.sync is Reloading(attempt=2, ..) else {
    fail("expected the second foreground attempt")
  }
  let (_, retrying3) = update_dev(dispatch, failure, retrying2)
  guard retrying3.find_conversation(@interop.ChannelId::Local, "desktop-a")
    is Some(conv3) &&
    conv3.sync is Reloading(attempt=3, ..) else {
    fail("expected the third foreground attempt")
  }
  let (_, next) = update_dev(dispatch, failure, retrying3)
  assert_true(next.loading_conversation is None)
  inspect(next.notifications.length(), content="1")
  inspect(
    next.notifications[0].message,
    content="Transcript refresh failed repeatedly. New commits are buffered; reopen the conversation or wait for the next update to retry. (failed to load session desktop-a: no such file)",
  )
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-a")
    is Some(failed) else {
    fail("expected the failed conversation")
  }
  assert_true(failed.sync is ReloadFailed(..))
  assert_true(
    next.notifications[0].message.has_prefix(TranscriptRefreshFailedNotice),
  )
  // The conversation on screen keeps its transcript and status untouched.
  inspect(next.active().messages.length(), content="0")
  assert_true(next.display_status() is Ready)
}

///|
test "session loaded swaps the active conversation onto the stored session" {
  let dispatch = test_dispatch()
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      messages: [
        {
          kind: User(content=Content([Text("old chat")])),
          ts: None,
          sequence: None,
        },
      ],
      turn: {
        ..test_conversation().turn,
        usage_tokens: 42,
        streaming_response: Some("leftover"),
      },
    })
    // The stored session is opened from its sidebar row, which is what
    // names the store it is read from.
    .with_dev(dev => {
      ..dev,
      sessions: [
        {
          id: "desktop-stored",
          title: Some("stored"),
          workspace: @interop.ChannelId::Local.test_project(),
          workspace_name: "work",
          updated_at_ms: None,
        },
      ],
    })
  let (_, loading) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-stored"),
    model,
  )
  let items : Array[@transcript.TranscriptItem] = [
    {
      kind: User(content=Content([Text("stored question")])),
      ts: None,
      sequence: None,
    },
    {
      kind: Assistant(
        reasoning=None,
        prose=Some("stored answer"),
        calls=[],
        replay=false,
        finished=false,
      ),
      ts: None,
      sequence: None,
    },
  ]
  let (_, once) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-stored",
      items~,
      watermark=0,
      generation=1,
    ),
    loading,
  )
  let (_, twice) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-stored",
      items~,
      watermark=0,
      generation=1,
    ),
    loading,
  )
  inspect(once.active_session, content="desktop-stored")
  inspect(once.active().messages.length(), content="2")
  assert_eq(once.active().messages[0].text(), Some("stored question"))
  assert_eq(once.active().turn.streaming_response, None)
  inspect(once.active().turn.usage_tokens, content="0")
  assert_eq(
    once.active().workspace,
    Project(root=@interop.ChannelId::Local.test_project()),
  )
  assert_true(once.display_status() is Ready)
  inspect(twice.active().messages.length(), content="2")
}

///|
test "session loaded adopts the store transcript and keeps live run state" {
  let dispatch = test_dispatch()
  let model = running_model().with_listed(["desktop-stored"])
  let items : Array[@transcript.TranscriptItem] = [
    { kind: User(content=Content([Text("stored")])), ts: None, sequence: None, },
  ]
  // The active conversation runs; loading some other stored session is fine.
  let (_, loading_other) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-stored"),
    model,
  )
  let (_, other) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-stored",
      items~,
      watermark=0,
      generation=1,
    ),
    loading_other,
  )
  inspect(other.active_session, content="desktop-stored")
  guard other.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(live) else {
    fail("expected the running conversation to survive")
  }
  inspect(live.is_running(), content="true")
  // A load reply for the running conversation itself adopts the store's
  // transcript — the source of truth for completed items — while the live
  // run state (phase, streaming buffers) rides across untouched.
  let streaming = running_model().replace_conversation({
    ..running_conversation(),
    turn: {
      ..running_conversation().turn,
      streaming_response: Some("mid-step"),
    },
  })
  let loading_same = {
    ..streaming.replace_conversation({
      ..streaming.active(),
      sync: test_reloading([]),
    }),
    loading_conversation: Some({ channel: Local, session: "desktop-test", }),
  }
  let (_, same) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session="desktop-test",
      items~,
      watermark=0,
      generation=1,
    ),
    loading_same,
  )
  inspect(same.active().messages.length(), content="1")
  assert_eq(same.active().messages[0].text(), Some("stored"))
  inspect(same.active().is_running(), content="true")
  assert_eq(same.active().turn.streaming_response, Some("mid-step"))
}
