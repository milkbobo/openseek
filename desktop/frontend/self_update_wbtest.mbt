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
/// Test-only: a model whose 0.2.0 download is staged and waits for the
/// restart click.
fn Model::with_staged_update(self : Model) -> Model {
  let dispatch = test_dispatch()
  let (_, downloading) = update(
    dispatch,
    SelfUpdate(
      CheckFinished(
        reply=Available(
          version="0.2.0",
          installable=true,
          unavailable_reason=None,
        ),
        explicit=false,
      ),
    ),
    self,
  )
  let (_, staged) = update(
    dispatch,
    SelfUpdate(Downloaded(version="0.2.0")),
    downloading,
  )
  staged
}

///|
test "a self-update problem pops one toast" {
  let dispatch = test_dispatch()
  let model = test_model().with_staged_update()
  let (_, restarting) = update(dispatch, SelfUpdate(UpdateClicked), model)
  let msg = SelfUpdate(Failed(message="the app location became read-only"))
  let (_, first) = update(dispatch, msg, restarting)
  let (_, replayed) = update(dispatch, msg, restarting)
  for failed in [first, replayed] {
    assert_eq(failed.notifications.length(), 1)
    assert_true(failed.notifications[0].message.contains("read-only"))
    assert_eq(failed.notification_seq, 1)
    assert_true(
      failed.self_update is Available(version="0.2.0", installable=false),
    )
  }
}

///|
test "restarting asks first only while a conversation runs" {
  let dispatch = test_dispatch()
  let idle = test_model().with_staged_update()
  let (_, restarting) = update(dispatch, SelfUpdate(UpdateClicked), idle)
  assert_true(restarting.self_update is Restarting(version="0.2.0"))
  let busy = idle.replace_conversation({
    ..test_conversation(),
    run: Starting(submission_id="pending-update"),
  })
  let (_, asked) = update(dispatch, SelfUpdate(UpdateClicked), busy)
  assert_true(asked.self_update is ConfirmingRestart(version="0.2.0"))
}

///|
test "switching the chat provider leaves the update answer alone" {
  let dispatch = test_dispatch()
  let (_, available) = update(
    dispatch,
    SelfUpdate(
      CheckFinished(
        reply=Available(
          version="0.2.0",
          installable=false,
          unavailable_reason=None,
        ),
        explicit=false,
      ),
    ),
    test_model(),
  )
  // A retired hosted-provider value lands on the BYOK default and the
  // update channel no longer derives from the chat provider.
  let (_, switched) = update(
    dispatch,
    HostSettings(ProviderChanged("openseek-staging")),
    available,
  )
  assert_true(switched.host_settings.provider() is Deepseek)
  assert_true(switched.self_update is Available(..))
  let (_, kept) = update(
    dispatch,
    HostSettings(ProviderChanged("custom")),
    available,
  )
  assert_true(kept.host_settings.provider() is Custom)
  assert_true(kept.self_update is Available(..))
}
