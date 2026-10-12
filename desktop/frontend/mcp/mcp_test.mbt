///|
fn quiet() -> @cmd.Emit[@mcp.Msg] {
  Emit(_ => @cmd.none)
}

///|
fn answer() -> @protocol.McpStatusReply {
  Configured(path="/home/.openseek/mcp.json", servers=[
    { name: "playwright", transport: Stdio, target: "npx", state: NoTools, },
  ])
}

///|
test "opening Settings checks once per host and keeps the answer" {
  let (_, checking) = @mcp.update(quiet(), Opened(Local), @mcp.State::initial())
  assert_true(checking.phase is Checking)
  assert_true(checking.host == Some(Local))
  let (_, loaded) = @mcp.update(
    quiet(),
    Checked(serial=checking.serial, Ok(answer())),
    checking,
  )
  assert_true(loaded.phase is Loaded(reply) && reply == answer())
  // Reopening Settings must not start the user's servers again.
  let (_, reopened) = @mcp.update(quiet(), Opened(Local), loaded)
  assert_true(reopened == loaded)
  // Another host has its own configuration: its answer is asked for.
  let (_, other) = @mcp.update(quiet(), Opened(Remote("device-a")), loaded)
  assert_true(other.phase is Checking)
  assert_true(other.host == Some(Remote("device-a")))
  assert_true(other.serial != loaded.serial)
}

///|
test "the answer to a superseded check is dropped" {
  let (_, first) = @mcp.update(quiet(), Opened(Local), @mcp.State::initial())
  let (_, second) = @mcp.update(quiet(), Opened(Remote("device-a")), first)
  let (_, stale) = @mcp.update(
    quiet(),
    Checked(serial=first.serial, Ok(answer())),
    second,
  )
  assert_true(stale == second)
  let (_, settled) = @mcp.update(
    quiet(),
    Checked(serial=second.serial, Err("device offline")),
    second,
  )
  assert_true(settled.phase is CheckFailed("device offline"))
  // An answer cannot arrive twice.
  let (_, again) = @mcp.update(
    quiet(),
    Checked(serial=second.serial, Ok(answer())),
    settled,
  )
  assert_true(again == settled)
}

///|
test "refresh asks again, but never while a check is running" {
  let initial = @mcp.State::initial()
  let (_, checking) = @mcp.update(quiet(), Opened(Local), initial)
  let (_, still) = @mcp.update(quiet(), Refresh(Local), checking)
  assert_true(still == checking)
  let (_, failed) = @mcp.update(
    quiet(),
    Checked(serial=checking.serial, Err("engine broke")),
    checking,
  )
  let (_, retried) = @mcp.update(quiet(), Refresh(Local), failed)
  assert_true(retried.phase is Checking)
  assert_true(retried.serial != failed.serial)
  assert_true(retried.host == Some(Local))
}

///|
test "an answer is shown only for the host that gave it" {
  let (_, checking) = @mcp.update(quiet(), Opened(Local), @mcp.State::initial())
  let (_, loaded) = @mcp.update(
    quiet(),
    Checked(serial=checking.serial, Ok(answer())),
    checking,
  )
  assert_true(loaded.phase_for(Local) is Loaded(_))
  // Another host was never asked; this one's servers are not its servers.
  assert_true(loaded.phase_for(Remote("device-a")) is Unchecked)
  // Refreshing there asks that host.
  let (_, asked) = @mcp.update(quiet(), Refresh(Remote("device-a")), loaded)
  assert_true(asked.phase_for(Remote("device-a")) is Checking)
  assert_true(asked.phase_for(Local) is Unchecked)
}
