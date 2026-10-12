///|
test "an unreadable library becomes the focused page's notice" {
  let dispatch = test_dispatch()
  let home = test_model()
  // Both devices are known, so a background reply reaches the handler proper
  // instead of being dropped for want of a device state.
  let paired = {
    ..home,
    devices: [
      home.devices[0],
      { ..empty_device_state(Remote("d_b")), bridge: Connected, },
    ],
  }
  let (_, noticed) = update(
    dispatch,
    FromDevice(Local, InstalledSkillsFailed("library unreadable")),
    paired,
  )
  assert_true(
    noticed.skills == paired.skills.with_library_error("library unreadable"),
  )

  // The page is the focused host's; a background device says nothing on it.
  let (_, quiet) = update(
    dispatch,
    FromDevice(Remote("d_b"), InstalledSkillsFailed("other host")),
    noticed,
  )
  assert_true(quiet.skills == noticed.skills)
}

///|
test "installed skills replies are scoped to their source device" {
  let dispatch = test_dispatch()
  let home = test_model()
  let focused = {
    ..home,
    devices: [
      home.devices[0],
      { ..empty_device_state(Remote("d_b")), bridge: Connected, },
    ],
    focused: Remote("d_b"),
    installed_skills: [],
  }
  let old_host : Array[@skills.InstalledItem] = [
    { id: "old", name: "old", description: "", source: "old/source@1.0.0", },
  ]
  let (_, ignored) = update(
    dispatch,
    FromDevice(Local, InstalledSkillsLoaded(old_host)),
    focused,
  )
  assert_eq(ignored.installed_skills.length(), 0)
  let new_host : Array[@skills.InstalledItem] = [
    { id: "new", name: "new", description: "", source: "new/source@1.0.0", },
  ]
  let (_, applied) = update(
    dispatch,
    FromDevice(Remote("d_b"), InstalledSkillsLoaded(new_host)),
    ignored,
  )
  assert_eq(applied.installed_skills.length(), 1)
  assert_eq(applied.installed_skills[0].id, "new")
}
