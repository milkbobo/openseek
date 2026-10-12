///|
test "reconnect refresh is single-flight and preserves its commit buffer" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [
      { kind: User(content=Content([Text("kept")])), ts: None, sequence: None, },
    ],
    watermark: 1,
  })
  let (_, refreshing) = update_dev(dispatch, BridgeReady, model)
  guard refreshing.active().sync is Reloading(generation=1, attempt=1, ..) else {
    fail("expected the first reconnect refresh")
  }
  let (_, buffered) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-test",
      sequence=3,
      ts=None,
      item=@protocol.User({
        content: Content([Text("future")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    refreshing,
  )
  let (_, reconnected_again) = update_dev(dispatch, BridgeReady, buffered)
  guard reconnected_again.active().sync
    is Reloading(generation=1, attempt=1, buffered=commits, ..) else {
    fail("a second reconnect started another generation")
  }
  inspect(commits.length(), content="1")
  inspect(commits[0].sequence, content="3")
}

///|
test "BridgeReady clears every non-replayable stream and compaction phase" {
  let dispatch = test_dispatch()
  let active = {
    ..test_conversation(),
    compaction: Queued,
    turn: {
      ..test_conversation().turn,
      streaming_response: Some("old answer"),
    },
  }
  let background = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-bg",
      @interop.ChannelId::Local.test_project(),
    ),
    compaction: Compacting,
    turn: {
      ..empty_conversation(
        @interop.ChannelId::Local,
        "desktop-bg",
        @interop.ChannelId::Local.test_project(),
      ).turn,
      streaming_response: Some("background answer"),
    },
  }
  let model = test_model()
    .replace_conversation(active)
    .replace_conversation(background)
  let (_, next) = update_dev(dispatch, BridgeReady, model)
  for conv in next.conversations {
    assert_eq(conv.turn.streaming_response, None)
    assert_true(conv.compaction is NotCompacting)
  }
}

///|
test "BridgeReady clears focused host settings until the refetch lands" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    host_settings: test_host_settings(
      provider="custom",
      revision=7,
      custom_api_url="https://old.example/chat",
      has_custom_key=true,
      messages=[SetupApiKeyChanged("old-key")],
    ),
  }
  let (_, next) = update_dev(dispatch, BridgeReady, model)
  assert_false(next.host_settings_loaded())
  assert_true(next.host_settings.provider() is Deepseek)
  inspect(next.host_settings.custom_api_url, content="")
  assert_false(next.host_settings.custom_key_saved)
  inspect(next.host_settings.setup_api_key, content="")
}

///|
test "BridgeReady resets only conversations owned by its channel" {
  let dispatch = test_dispatch()
  let background : @interop.ChannelId = Remote("d-bg")
  let local_conv = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "shared",
      @interop.ChannelId::Local.test_project(),
    ),
    compaction: Queued,
    turn: {
      ..empty_conversation(
        @interop.ChannelId::Local,
        "shared",
        @interop.ChannelId::Local.test_project(),
      ).turn,
      streaming_response: Some("local answer"),
    },
  }
  let remote = {
    ..empty_conversation(background, "shared", background.test_project()),
    compaction: Compacting,
    turn: {
      ..empty_conversation(background, "shared", background.test_project()).turn,
      streaming_response: Some("remote answer"),
    },
  }
  let model = {
    ..test_model(),
    devices: [
      { ..empty_device_state(@interop.ChannelId::Local), bridge: Connected, },
      { ..empty_device_state(background), bridge: Connected, },
    ],
    active_session: "shared",
    conversations: [local_conv, remote],
  }
  let (_, next) = update(dispatch, FromDevice(background, BridgeReady), model)
  guard next.find_conversation(@interop.ChannelId::Local, "shared")
    is Some(kept) &&
    next.find_conversation(background, "shared") is Some(reset) else {
    fail("same-id conversations were not preserved")
  }
  assert_eq(kept.turn.streaming_response, Some("local answer"))
  assert_true(kept.compaction is Queued)
  assert_eq(reset.turn.streaming_response, None)
  assert_true(reset.compaction is NotCompacting)
}

///|
test "socket losses mark the bridge lost at the third consecutive drop" {
  let dispatch = test_dispatch()
  let channel : @interop.ChannelId = Remote("d1")
  let model = {
    ..initial_model(desktop=false),
    devices: [{ ..empty_device_state(channel), bridge: Connected, }],
    focused: channel,
  }
  let (_, one) = update(
    dispatch,
    FromDevice(channel, ChannelDown(websocket_epoch=0)),
    model,
  )
  let (_, due) = update(
    dispatch,
    FromDevice(channel, ReconnectDue(websocket_epoch=0)),
    one,
  )
  inspect(due.dev().reconnect_attempt, content="1")
  // Terminal retirement is covered by the terminal component's disconnect
  // test; the application state owns only the reconnect policy now.
  let (_, two) = update(
    dispatch,
    FromDevice(channel, ChannelDown(websocket_epoch=0)),
    due,
  )
  inspect(two.dev().reconnect_failures, content="2")
  assert_true(two.bridge_state() is Connected)
  let (_, three) = update(
    dispatch,
    FromDevice(channel, ChannelDown(websocket_epoch=0)),
    two,
  )
  assert_true(three.bridge_state() is BridgeLost(_))
}

///|
test "BridgeReady resets the reconnect failure count" {
  let dispatch = test_dispatch()
  let channel : @interop.ChannelId = Remote("d1")
  let model = {
    ..initial_model(desktop=false),
    devices: [
      {
        ..empty_device_state(channel),
        reconnect_failures: 2,
        bridge: BridgeLost("gone"),
      },
    ],
    focused: channel,
  }
  let (_, next) = update(dispatch, FromDevice(channel, BridgeReady), model)
  inspect(next.dev().reconnect_failures, content="0")
  assert_true(next.bridge_state() is Connected)
}

///|
test "late reconnect ticks cannot act on removed or re-added devices" {
  let dispatch = test_dispatch()
  let channel : @interop.ChannelId = Remote("gone")
  let model = test_model()
  let (_, next) = update(
    dispatch,
    FromDevice(channel, ReconnectDue(websocket_epoch=1)),
    model,
  )
  inspect(next.devices.length(), content="1")
  assert_true(next.device_state(channel) is None)
  // Reusing the relay id after sign-out is not reusing the connection. The
  // page-wide epoch survives account teardown and advances when the roster
  // adopts the same id again.
  let roster : Array[DeviceMeta] = [
    { id: "same", name: "Mac", hostname: None, online: true, },
  ]
  let console_model = {
    ..console_test_model(),
    console: empty_console_state(Some("same"), None),
  }
  let (_, signed) = update(
    dispatch,
    Console(MeLoaded(login="o", avatar="")),
    console_model,
  )
  let (_, first) = update(
    dispatch,
    Console(RosterLoaded(roster, generation=1)),
    signed,
  )
  let same : @interop.ChannelId = Remote("same")
  guard first.device_state(same) is Some(first_dev) else {
    fail("first device connection missing")
  }
  inspect(first_dev.websocket_epoch, content="1")
  let (_, out) = update(dispatch, Console(MeUnauthorized), first)
  let (_, signed_again) = update(
    dispatch,
    Console(MeLoaded(login="o", avatar="")),
    out,
  )
  let (_, current) = update(
    dispatch,
    Console(RosterLoaded(roster, generation=2)),
    signed_again,
  )
  guard current.device_state(same) is Some(current_dev) else {
    fail("re-added device connection missing")
  }
  inspect(current_dev.websocket_epoch, content="2")
  let (_, stale) = update(
    dispatch,
    FromDevice(same, ReconnectDue(websocket_epoch=1)),
    current,
  )
  assert_true(stale.devices == current.devices)
  inspect(stale.websocket_epoch, content="2")
}

///|
test "an explicit rejected fresh start does not force reconnect reloads" {
  let dispatch = test_dispatch()
  let conv = with_pending_prompt(
    { ..test_conversation(), run: Starting(submission_id="rejected-id"), },
    "rejected-id",
    "try this",
  )
  let (_, rejected) = update_dev(
    dispatch,
    StartRejected(
      session="desktop-test",
      submission_id="rejected-id",
      message="host refused",
    ),
    test_model().replace_conversation(conv),
  )
  inspect(rejected.active().pending_steers.length(), content="0")
  let (_, reconnected) = update_dev(dispatch, BridgeReady, rejected)
  assert_true(reconnected.active().sync is Synced)
  inspect(reconnected.transcript_request_generation, content="0")
}
