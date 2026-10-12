///|
fn quiet() -> @cmd.Emit[@mcp.Msg] {
  Emit(_ => @cmd.none)
}

///|
fn conversation(session : String) -> @interop.ConversationKey {
  { channel: Local, session, }
}

///|
fn answer() -> @protocol.McpStatusReply {
  {
    config_path: "/home/.openseek/mcp.json",
    engine: Running(
      Configured(path="/home/.openseek/mcp.json", servers=[
        { name: "playwright", transport: Stdio, target: "npx", state: NoTools, },
      ]),
    ),
  }
}

///|
test "opening Settings asks the current conversation's engine, every time" {
  let one = conversation("s-1")
  let (_, checking) = @mcp.update(
    quiet(),
    Opened(Some(one)),
    @mcp.State::initial(),
  )
  assert_true(checking.phase is Checking)
  assert_true(checking.conversation == Some(one))
  let (_, loaded) = @mcp.update(
    quiet(),
    Checked(serial=checking.serial, Ok(answer())),
    checking,
  )
  assert_true(loaded.phase is Loaded(reply) && reply == answer())
  // The answer is the engine's state when asked, and asking starts nothing,
  // so reopening Settings asks again rather than showing an old answer.
  let (_, reopened) = @mcp.update(quiet(), Opened(Some(one)), loaded)
  assert_true(reopened.phase is Checking)
  assert_true(reopened.serial != loaded.serial)
}

///|
test "the answer to a superseded question is dropped" {
  let (_, first) = @mcp.update(
    quiet(),
    Opened(Some(conversation("s-1"))),
    @mcp.State::initial(),
  )
  let (_, second) = @mcp.update(
    quiet(),
    Opened(Some(conversation("s-2"))),
    first,
  )
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
  // Opening Settings with no conversation retires a question still out.
  let (_, none) = @mcp.update(quiet(), Opened(None), second)
  assert_true(none.phase is Unchecked)
  let (_, late) = @mcp.update(
    quiet(),
    Checked(serial=second.serial, Ok(answer())),
    none,
  )
  assert_true(late == none)
}

///|
test "refresh asks again, but never while a question is out" {
  let one = conversation("s-1")
  let (_, checking) = @mcp.update(
    quiet(),
    Opened(Some(one)),
    @mcp.State::initial(),
  )
  let (_, still) = @mcp.update(quiet(), Refresh(one), checking)
  assert_true(still == checking)
  let (_, failed) = @mcp.update(
    quiet(),
    Checked(serial=checking.serial, Err("engine did not answer")),
    checking,
  )
  let (_, retried) = @mcp.update(quiet(), Refresh(one), failed)
  assert_true(retried.phase is Checking)
  assert_true(retried.serial != failed.serial)
  assert_true(retried.conversation == Some(one))
}

///|
test "an answer is shown only for the conversation whose engine gave it" {
  let one = conversation("s-1")
  let two = conversation("s-2")
  let (_, checking) = @mcp.update(
    quiet(),
    Opened(Some(one)),
    @mcp.State::initial(),
  )
  let (_, loaded) = @mcp.update(
    quiet(),
    Checked(serial=checking.serial, Ok(answer())),
    checking,
  )
  assert_true(loaded.phase_for(Some(one)) is Loaded(_))
  // Another conversation has its own engine, and no conversation has none.
  assert_true(loaded.phase_for(Some(two)) is Unchecked)
  assert_true(loaded.phase_for(None) is Unchecked)
  // The same session id on another host is another conversation.
  assert_true(
    loaded.phase_for(Some({ channel: Remote("device-a"), session: "s-1", }))
    is Unchecked,
  )
  let (_, asked) = @mcp.update(quiet(), Refresh(two), loaded)
  assert_true(asked.phase_for(Some(two)) is Checking)
  assert_true(asked.phase_for(Some(one)) is Unchecked)
}
