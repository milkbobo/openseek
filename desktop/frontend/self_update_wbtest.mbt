///|
test "AppInfoLoaded replaces the displayed package version idempotently" {
  let dispatch = test_dispatch()
  let info = AppInfoLoaded(
    version="0.2.0",
    console_url=Some("http://127.0.0.1:27183/?token=sesame"),
  )
  let (_, once) = update(dispatch, info, test_model())
  let (_, twice) = update(dispatch, info, once)
  assert_eq(once.app_version, "0.2.0")
  assert_eq(once.console_url, Some("http://127.0.0.1:27183/?token=sesame"))
  assert_eq(twice.app_version, once.app_version)
  assert_eq(twice.notification_seq, once.notification_seq)
}

///|
test "a check finding an installable release downloads it by itself" {
  let dispatch = test_dispatch()
  let found = CheckFound(
    version="0.2.0",
    installable=true,
    unavailable_reason=None,
  )
  // The quiet startup check and the user asking from Settings download the
  // same way; only the restart waits for a click.
  for explicit in [false, true] {
    let (_, next) = update(
      dispatch,
      UpdateCheckFinished(result=found, explicit~),
      test_model(),
    )
    assert_true(next.update_ux is DownloadingUpdate(version="0.2.0", ..))
    assert_eq(next.notifications.length(), 0)
  }
}

///|
test "an unavailable startup update reports why without offering Update" {
  let dispatch = test_dispatch()
  let model = test_model()
  let msg = UpdateCheckFinished(
    result=CheckFound(
      version="0.2.0",
      installable=false,
      unavailable_reason=Some("Move SeekMoon.app to Applications."),
    ),
    explicit=false,
  )
  let (_, first) = update(dispatch, msg, model)
  let (_, replayed) = update(dispatch, msg, model)
  for result in [first, replayed] {
    assert_true(
      result.update_ux is UpdateAvailable(version="0.2.0", installable=false),
    )
    assert_eq(result.notifications.length(), 1)
    inspect(
      result.notifications[0].message,
      content="Move SeekMoon.app to Applications.",
    )
    assert_eq(result.notification_seq, 1)
  }
}

///|
test "a package-less release stays informational" {
  let dispatch = test_dispatch()
  let (_, model) = update(
    dispatch,
    UpdateCheckFinished(
      result=CheckFound(
        version="0.2.0",
        installable=false,
        unavailable_reason=None,
      ),
      explicit=false,
    ),
    test_model(),
  )
  assert_true(
    model.update_ux is UpdateAvailable(version="0.2.0", installable=false),
  )
  assert_eq(model.notifications.length(), 0)
}

///|
test "quiet startup outcomes leave no trace; explicit ones answer" {
  let dispatch = test_dispatch()
  for
    result in [
      CheckUpToDate,
      CheckUnreachable(reason="offline"),
      CheckMalformed(reason="not json"),
    ] {
    let (_, silent) = update(
      dispatch,
      UpdateCheckFinished(result~, explicit=false),
      test_model(),
    )
    assert_true(silent.update_ux is UpdateUnknown)
    assert_eq(silent.notifications.length(), 0)
  }
  let (_, ok) = update(
    dispatch,
    UpdateCheckFinished(result=CheckUpToDate, explicit=true),
    test_model(),
  )
  assert_true(ok.update_ux is UpToDate)
  let (_, offline) = update(
    dispatch,
    UpdateCheckFinished(
      result=CheckUnreachable(reason="offline"),
      explicit=true,
    ),
    test_model(),
  )
  assert_true(
    offline.update_ux is UpdateCheckFailed(..) &&
    offline.update_ux is UpdateCheckFailed(message~) &&
    message.contains("offline"),
  )
}

///|
test "a broken package entry is loud even when the app asked" {
  let dispatch = test_dispatch()
  let (_, model) = update(
    dispatch,
    UpdateCheckFinished(
      result=CheckBroken(version="0.2.0", reason="url is not https"),
      explicit=false,
    ),
    test_model(),
  )
  assert_eq(model.notifications.length(), 1)
  assert_true(model.notifications[0].message.contains("url is not https"))
  assert_true(model.update_ux is UpdateCheckFailed(..))
}

///|
test "a finished download stages the release; restarting stays a click away" {
  let dispatch = test_dispatch()
  let downloading = {
    ..test_model(),
    update_ux: DownloadingUpdate(version="0.2.0", progress={
      downloaded_bytes: 0,
      total_bytes: None,
    }),
  }
  let progress = UpdateDownloadProgress(
    downloaded_bytes=42,
    total_bytes=Some(100),
  )
  let (_, progressed) = update(dispatch, progress, downloading)
  let (_, replayed) = update(dispatch, progress, downloading)
  assert_true(progressed.update_ux == replayed.update_ux)
  assert_true(
    progressed.update_ux
    is DownloadingUpdate(
      version="0.2.0",
      progress={ downloaded_bytes: 42, total_bytes: Some(100), }
    ),
  )
  // Downloaded stages the release instead of swapping it: restarting is the
  // user's call.
  let (_, staged) = update(
    dispatch,
    UpdateDownloaded(version="0.2.0"),
    progressed,
  )
  assert_true(staged.update_ux is UpdateReady(version="0.2.0"))
  // With nothing running, the restart click applies immediately.
  let (_, clicked) = update(dispatch, UpdateClicked, staged)
  assert_true(clicked.update_ux is RestartingForUpdate(version="0.2.0"))
}

///|
test "the staged version comes from the host, not the stale check" {
  let dispatch = test_dispatch()
  let downloading = {
    ..test_model(),
    update_ux: DownloadingUpdate(version="0.2.0", progress={
      downloaded_bytes: 0,
      total_bytes: None,
    }),
  }
  // The host's download-time re-check staged a release newer than the one
  // this flow started from; the notification's version wins.
  let (_, staged) = update(
    dispatch,
    UpdateDownloaded(version="0.2.1"),
    downloading,
  )
  assert_true(staged.update_ux is UpdateReady(version="0.2.1"))
}

///|
test "clicking the restored offer retries the download" {
  let dispatch = test_dispatch()
  let available = {
    ..test_model(),
    update_ux: UpdateAvailable(version="0.2.0", installable=true),
  }
  // A retry starts the download again; it is harmless while conversations
  // run, so it does not ask first.
  let (_, clicked) = update(dispatch, UpdateClicked, available)
  assert_true(clicked.update_ux is DownloadingUpdate(version="0.2.0", ..))
}

///|
test "a staged release survives stale check replies and re-check clicks" {
  let dispatch = test_dispatch()
  let staged = { ..test_model(), update_ux: UpdateReady(version="0.2.0"), }
  let (_, after_reply) = update(
    dispatch,
    UpdateCheckFinished(result=CheckUpToDate, explicit=false),
    staged,
  )
  assert_true(after_reply.update_ux is UpdateReady(version="0.2.0"))
  let (_, after_click) = update(dispatch, CheckForUpdates, staged)
  assert_true(after_click.update_ux is UpdateReady(version="0.2.0"))
}

///|
test "restarting asks first while a conversation runs" {
  let dispatch = test_dispatch()
  let busy = {
    ..test_model().replace_conversation({
      ..test_conversation(),
      run: Starting(submission_id="pending-update"),
    }),
    update_ux: UpdateReady(version="0.2.0"),
  }
  let (_, asked) = update(dispatch, UpdateClicked, busy)
  assert_true(asked.update_ux is ConfirmingRestart(version="0.2.0"))
  // Cancel parks the staged release; confirm applies it.
  let (_, kept) = update(dispatch, CancelUpdateRestart, asked)
  assert_true(kept.update_ux is UpdateReady(version="0.2.0"))
  let (_, confirmed) = update(dispatch, ConfirmUpdateRestart, asked)
  assert_true(confirmed.update_ux is RestartingForUpdate(version="0.2.0"))
}

///|
test "a failed download says why and restores the offer" {
  let dispatch = test_dispatch()
  let downloading = {
    ..test_model(),
    update_ux: DownloadingUpdate(version="0.2.0", progress={
      downloaded_bytes: 42,
      total_bytes: Some(100),
    }),
  }
  let (_, failed) = update(
    dispatch,
    UpdateFailed(message="digest mismatch"),
    downloading,
  )
  assert_eq(failed.notifications.length(), 1)
  assert_true(failed.notifications[0].message.contains("digest mismatch"))
  assert_true(
    failed.update_ux is UpdateAvailable(version="0.2.0", installable=true),
  )
}

///|
test "a failed apply says why and withdraws the offer" {
  let dispatch = test_dispatch()
  let restarting = {
    ..test_model(),
    update_ux: RestartingForUpdate(version="0.2.0"),
  }
  let msg = UpdateFailed(message="the app location became read-only")
  let (_, first) = update(dispatch, msg, restarting)
  let (_, replayed) = update(dispatch, msg, restarting)
  for failed in [first, replayed] {
    assert_eq(failed.notifications.length(), 1)
    assert_true(failed.notifications[0].message.contains("read-only"))
    assert_eq(failed.notification_seq, 1)
    assert_true(
      failed.update_ux is UpdateAvailable(version="0.2.0", installable=false),
    )
  }
}

///|
test "a stale check reply cannot clobber a download in flight" {
  let dispatch = test_dispatch()
  let downloading = {
    ..test_model(),
    update_ux: DownloadingUpdate(version="0.2.0", progress={
      downloaded_bytes: 42,
      total_bytes: Some(100),
    }),
  }
  let (_, next) = update(
    dispatch,
    UpdateCheckFinished(result=CheckUpToDate, explicit=false),
    downloading,
  )
  assert_true(next.update_ux is DownloadingUpdate(version="0.2.0", ..))
}

///|
test "late update progress cannot revive an available release" {
  let dispatch = test_dispatch()
  let available = {
    ..test_model(),
    update_ux: UpdateAvailable(version="0.2.0", installable=true),
  }
  let msg = UpdateDownloadProgress(downloaded_bytes=42, total_bytes=Some(100))
  let (_, first) = update(dispatch, msg, available)
  let (_, replayed) = update(dispatch, msg, available)
  assert_true(first.update_ux == available.update_ux)
  assert_true(replayed.update_ux == available.update_ux)
}

///|
test "switching the chat provider leaves the update answer alone" {
  let dispatch = test_dispatch()
  let available = {
    ..test_model(),
    update_ux: UpdateAvailable(version="0.2.0", installable=true),
  }
  // A retired hosted-provider value lands on the BYOK default and the
  // update channel no longer derives from the chat provider.
  let (_, switched) = update(
    dispatch,
    ProviderChanged("openseek-staging"),
    available,
  )
  assert_true(switched.api_provider is Deepseek)
  assert_true(switched.update_ux is UpdateAvailable(..))
  let (_, kept) = update(dispatch, ProviderChanged("custom"), available)
  assert_true(kept.api_provider is Custom)
  assert_true(kept.update_ux is UpdateAvailable(..))
}
