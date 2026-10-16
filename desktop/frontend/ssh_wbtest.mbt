///|
test "SSH readiness updates the remote host without replacing local state" {
  let profile : @protocol.SshProfile = {
    id: "ssh-ready-test",
    command: "ssh build",
    server: "openseek",
  }
  let model = { ..test_model(), is_desktop: true, }.register_ssh(profile)
  let local_device = model.device_state(Local)
  let (_, connected) = update_ssh(
    test_dispatch(),
    Event({
      "host_id": profile.id,
      "epoch": 3,
      "event": { "method": "agent.connected", "params": {} },
    }),
    model,
  )
  assert_true(
    connected.device_state(Remote(profile.id))
    is Some({ bridge: Connected, .. }),
  )
  assert_eq(connected.focused, Local)
  assert_true(connected.device_state(Local) == local_device)
  let (_, stale) = update_ssh(
    test_dispatch(),
    Event({
      "host_id": profile.id,
      "epoch": 2,
      "event": { "disconnected": "old transport" },
    }),
    connected,
  )
  assert_true(
    stale.device_state(Remote(profile.id)) is Some({ bridge: Connected, .. }),
  )
  @interop.set_ssh_epoch(Remote(profile.id), None)
}

///|
test "SSH disconnect retains project identity and removes request readiness" {
  let profile : @protocol.SshProfile = {
    id: "ssh-offline-test",
    command: "ssh build",
    server: "openseek",
  }
  let channel : @interop.ChannelId = Remote(profile.id)
  let model = { ..test_model(), is_desktop: true, }.register_ssh(profile)
  let root = channel.test_project()
  let model = model.replace_device({
    ..empty_device_state(channel),
    bridge: Connected,
    projects: [root],
  })
  @interop.set_ssh_epoch(channel, Some(4))
  let (_, offline) = update_ssh(
    test_dispatch(),
    Event({
      "host_id": profile.id,
      "epoch": 4,
      "event": { "disconnected": "connection lost" },
    }),
    model,
  )
  assert_true(
    offline.device_state(channel)
    is Some({ bridge: BridgeLost("connection lost"), projects: [saved], .. }) &&
    saved == root,
  )
  assert_eq(@interop.current_ssh_epoch(channel), None)
}

///|
test "adding SSH from the project picker survives navigation reconciliation" {
  let dispatch = test_dispatch()
  let (_, initial) = update(dispatch, ToggleSidebar, {
    ..test_model(),
    is_desktop: true,
  })
  let (_, picker) = update(dispatch, PickProject(Local), initial)
  assert_true(picker.project_picker is Some(_))
  let (_, opened) = update(dispatch, Ssh(Open), picker)
  assert_true(opened.project_picker is None)
  assert_true(opened.screen is Settings)
  assert_true(opened.navigation.location is Some({ target: Settings, .. }))
  let (_, settled) = update(dispatch, ToggleSidebar, opened)
  assert_true(settled.screen is Settings)
  let (_, back) = update(dispatch, Navigation(Back), settled)
  assert_true(back.screen is Chat)
}

///|
test "SSH preparation progress can be cancelled and does not revive an offline host" {
  let dispatch = test_dispatch()
  let profile : @protocol.SshProfile = {
    id: "ssh-prepare-test",
    command: "ssh build",
    server: "openseek",
  }
  let model = { ..test_model(), is_desktop: true, }.register_ssh(profile)
  let (_, connecting) = update_ssh(dispatch, Connect(profile.id), model)
  let event = Event({
    "host_id": profile.id,
    "epoch": 1,
    "event": { "stage": "installing" },
  })
  let (_, preparing) = update_ssh(dispatch, event, connecting)
  assert_eq(
    preparing.ssh_ui.connecting.get(profile.id),
    Some("Running openseek setup…"),
  )
  let (_, cancelled) = update_ssh(dispatch, Disconnect(profile.id), preparing)
  let (_, stale) = update_ssh(dispatch, event, cancelled)
  assert_false(stale.ssh_ui.connecting.contains(profile.id))
  assert_eq(@interop.current_ssh_epoch(Remote(profile.id)), None)
}
