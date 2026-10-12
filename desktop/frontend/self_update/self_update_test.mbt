// The flow as the shell sees it: every state below is reached by sending the
// messages a host and a user would send, starting from `State::empty()`.

///|
fn emit() -> @cmd.Emit[@self_update.Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
/// One transition with nothing running, unless `busy` says otherwise.
fn step(
  state : @self_update.State,
  msg : @self_update.Msg,
  busy~ : Bool = false,
) -> (@self_update.State, Array[@self_update.Event]) {
  let (state, _, events) = @self_update.update(state, msg, emit(), busy~)
  (state, events)
}

///|
fn check_finished(
  reply : @protocol.CheckUpdateReply,
  explicit~ : Bool = false,
) -> @self_update.Msg {
  CheckFinished(reply~, explicit~)
}

///|
fn found(
  installable~ : Bool = true,
  unavailable_reason? : String,
) -> @protocol.CheckUpdateReply {
  Available(version="0.2.0", installable~, unavailable_reason~)
}

///|
/// A check found 0.2.0 and its download is in flight.
fn downloading() -> @self_update.State {
  step(@self_update.State::empty(), check_finished(found())).0
}

///|
/// 0.2.0 is downloaded and waits for the restart.
fn staged() -> @self_update.State {
  step(downloading(), Downloaded(version="0.2.0")).0
}

///|
/// The download failed, which restores the offer to retry it.
fn offered() -> @self_update.State {
  step(downloading(), Failed(message="digest mismatch")).0
}

///|
test "a check finding an installable release downloads it by itself" {
  // The quiet startup check and the user asking from Settings download the
  // same way; only the restart waits for a click.
  for explicit in [false, true] {
    let (next, events) = step(
      @self_update.State::empty(),
      check_finished(found(), explicit~),
    )
    assert_true(next is Downloading(version="0.2.0", ..))
    assert_eq(events, [])
  }
}

///|
test "an unavailable startup update reports why without offering Update" {
  let msg = check_finished(
    found(
      installable=false,
      unavailable_reason="Move SeekMoon.app to Applications.",
    ),
  )
  let first = step(@self_update.State::empty(), msg)
  let replayed = step(@self_update.State::empty(), msg)
  for result in [first, replayed] {
    let (state, events) = result
    assert_true(state is Available(version="0.2.0", installable=false))
    assert_eq(events, [Problem("Move SeekMoon.app to Applications.")])
  }
}

///|
test "a package-less release stays informational" {
  let (state, events) = step(
    @self_update.State::empty(),
    check_finished(found(installable=false)),
  )
  assert_true(state is Available(version="0.2.0", installable=false))
  assert_eq(events, [])
}

///|
test "quiet startup outcomes leave no trace; explicit ones answer" {
  let replies : Array[@protocol.CheckUpdateReply] = [
    UpToDate,
    Unreachable(reason="offline"),
    Malformed(reason="not json"),
  ]
  for reply in replies {
    let (silent, events) = step(
      @self_update.State::empty(),
      check_finished(reply),
    )
    assert_true(silent is Unknown)
    assert_eq(events, [])
  }
  let (ok, _) = step(
    @self_update.State::empty(),
    check_finished(UpToDate, explicit=true),
  )
  assert_true(ok is UpToDate)
  let (offline, _) = step(
    @self_update.State::empty(),
    check_finished(Unreachable(reason="offline"), explicit=true),
  )
  assert_true(offline is CheckFailed(message~) && message.contains("offline"))
}

///|
test "a broken package entry is loud even when the app asked" {
  let (state, events) = step(
    @self_update.State::empty(),
    check_finished(Broken(version="0.2.0", reason="url is not https")),
  )
  assert_true(
    events is [Problem(message)] && message.contains("url is not https"),
  )
  assert_true(state is CheckFailed(..))
}

///|
test "a finished download stages the release; restarting stays a click away" {
  let progress : @self_update.Msg = DownloadProgress(
    downloaded_bytes=42,
    total_bytes=Some(100),
  )
  let (progressed, _) = step(downloading(), progress)
  let (replayed, _) = step(downloading(), progress)
  assert_true(progressed == replayed)
  assert_true(
    progressed
    is Downloading(
      version="0.2.0",
      progress={ downloaded_bytes: 42, total_bytes: Some(100), }
    ),
  )
  // Downloaded stages the release instead of swapping it: restarting is the
  // user's call.
  let (staged, _) = step(progressed, Downloaded(version="0.2.0"))
  assert_true(staged is Ready(version="0.2.0"))
  // With nothing running, the restart click applies immediately.
  let (clicked, _) = step(staged, UpdateClicked)
  assert_true(clicked is Restarting(version="0.2.0"))
}

///|
test "the staged version comes from the host, not the stale check" {
  // The host's download-time re-check staged a release newer than the one
  // this flow started from; the notification's version wins.
  let (staged, _) = step(downloading(), Downloaded(version="0.2.1"))
  assert_true(staged is Ready(version="0.2.1"))
}

///|
test "clicking the restored offer retries the download" {
  // A retry starts the download again; it is harmless while conversations
  // run, so it does not ask first.
  let (clicked, _) = step(offered(), UpdateClicked, busy=true)
  assert_true(clicked is Downloading(version="0.2.0", ..))
}

///|
test "a staged release survives stale check replies and re-check clicks" {
  let (after_reply, _) = step(staged(), check_finished(UpToDate))
  assert_true(after_reply is Ready(version="0.2.0"))
  let (after_click, _) = step(staged(), CheckClicked)
  assert_true(after_click is Ready(version="0.2.0"))
}

///|
test "restarting asks first while a conversation runs" {
  let (asked, _) = step(staged(), UpdateClicked, busy=true)
  assert_true(asked is ConfirmingRestart(version="0.2.0"))
  // Cancel parks the staged release; confirm applies it.
  let (kept, _) = step(asked, RestartCancelled, busy=true)
  assert_true(kept is Ready(version="0.2.0"))
  let (confirmed, _) = step(asked, RestartConfirmed, busy=true)
  assert_true(confirmed is Restarting(version="0.2.0"))
}

///|
test "a failed download says why and restores the offer" {
  let (progressed, _) = step(
    downloading(),
    DownloadProgress(downloaded_bytes=42, total_bytes=Some(100)),
  )
  let (failed, events) = step(progressed, Failed(message="digest mismatch"))
  assert_eq(events, [Problem("digest mismatch")])
  assert_true(failed is Available(version="0.2.0", installable=true))
}

///|
test "a failed apply says why and withdraws the offer" {
  let (restarting, _) = step(staged(), UpdateClicked)
  let msg : @self_update.Msg = Failed(
    message="the app location became read-only",
  )
  let first = step(restarting, msg)
  let replayed = step(restarting, msg)
  for result in [first, replayed] {
    let (failed, events) = result
    assert_eq(events, [Problem("the app location became read-only")])
    assert_true(failed is Available(version="0.2.0", installable=false))
  }
}

///|
test "a stale check reply cannot clobber a download in flight" {
  let (next, _) = step(downloading(), check_finished(UpToDate))
  assert_true(next is Downloading(version="0.2.0", ..))
}

///|
test "late update progress cannot revive an available release" {
  let msg : @self_update.Msg = DownloadProgress(
    downloaded_bytes=42,
    total_bytes=Some(100),
  )
  let (first, _) = step(offered(), msg)
  let (replayed, _) = step(offered(), msg)
  assert_true(first == offered())
  assert_true(replayed == offered())
}

///|
test "the accent button follows the flow" {
  assert_eq(@self_update.State::empty().button_label(English), None)
  assert_eq(offered().button_label(English), Some("Update"))
  assert_eq(downloading().button_label(English), Some("Downloading…"))
  assert_eq(staged().button_label(English), Some("Restart to update"))
  assert_true(offered().button_enabled())
  assert_true(staged().button_enabled())
  assert_false(downloading().button_enabled())
}
