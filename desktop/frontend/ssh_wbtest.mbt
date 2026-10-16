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
