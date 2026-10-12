///|
test "the GLM provider aligns only a fresh chat to its model family" {
  let dispatch = test_dispatch()
  let (_, glm) = update(dispatch, HostSettings(ProviderChanged("glm")), {
    ..test_model(),
    host_settings: test_host_settings(has_deepseek_key=true, has_glm_key=true),
  })
  assert_true(glm.host_settings.provider() is Glm)
  assert_true(glm.default_model is Glm53)
  assert_true(glm.active().engine_model is Glm53)
  // GLM's forced-thinking default is the shared low wire value, independent
  // from the High preference DeepSeek keeps.
  assert_true(glm.reasoning_for(glm.active().engine_model) is ReasoningOff)
  assert_true(glm.openseek_reasoning is ReasoningHigh)
  // A host snapshot on a later launch performs the same alignment even
  // though the page-local model preference loads before host settings do.
  let (_, restored) = update_dev(
    dispatch,
    HostSettings(
      Loaded(host_settings(provider="glm", has_glm_key=true)),
      connection_generation=None,
    ),
    test_model(),
  )
  assert_true(restored.default_model is Glm53)
  assert_true(restored.active().engine_model is Glm53)
  // Startup is order-independent: if the host's GLM snapshot arrives before
  // localStorage, the later DeepSeek model preference cannot reintroduce a
  // mismatched fresh chat.
  let (_, preferences_after_host) = update(
    dispatch,
    SettingsLoaded(
      notification_corner=None,
      tree_layout=None,
      theme=None,
      font_size=None,
      fps_overlay_enabled=false,
      minimal_transcript=false,
      model=Some("deepseek-v4-pro"),
      conversation_models=None,
      agent=None,
      codex_model=None,
      codex_effort=None,
      openseek_effort=None,
      glm_effort=None,
    ),
    restored,
  )
  assert_true(preferences_after_host.default_model is Glm53)
  assert_true(preferences_after_host.active().engine_model is Glm53)
  // Once a conversation has begun, its pinned model remains explicit and
  // visible for the user to change rather than being rewritten by Settings.
  let (_, running) = update(
    dispatch,
    HostSettings(ProviderChanged("glm")),
    running_model(),
  )
  assert_true(running.host_settings.provider() is Glm)
  assert_true(running.default_model is Glm53)
  assert_true(running.active().engine_model is DsPro)
  assert_true(running.display_status() is Running)
}

///|
test "the composer's BYOK notice outlives a dismissal and reopens the modal" {
  let dispatch = test_dispatch()
  let (_, keyless) = update_dev(
    dispatch,
    HostSettings(
      Loaded(host_settings(provider="deepseek")),
      connection_generation=None,
    ),
    test_model(),
  )
  let (_, dismissed) = update(dispatch, HostSettings(DismissApiSetup), keyless)
  // Quiet must not mean lost: the notice stays while the endpoint is
  // unusable, dismissal or not.
  assert_true(dismissed.api_setup_banner_visible())
  // The loading sentinel is not a verdict; a reconnect must not flash it.
  assert_true(!dismissed.clear_host_settings().api_setup_banner_visible())
  // A usable endpoint retires the notice with the modal.
  assert_true(!test_model().api_setup_banner_visible())
  // Its "Set up" reopens the modal, and reopening cancels the dismissal so
  // the next settled snapshot leaves the modal the user asked for alone.
  let (_, reopened) = update(dispatch, HostSettings(OpenApiSetup), dismissed)
  assert_true(reopened.host_settings.api_setup_open)
  let (_, still_open) = update_dev(
    dispatch,
    HostSettings(
      Loaded(host_settings(provider="deepseek")),
      connection_generation=None,
    ),
    reopened,
  )
  assert_true(still_open.host_settings.api_setup_open)
}

///|
test "a background device's pushes leave the focused mirrors alone" {
  let dispatch = test_dispatch()
  let background : @interop.ChannelId = Remote("d_bg")
  let model = {
    ..test_model(),
    devices: [
      { ..empty_device_state(@interop.ChannelId::Local), bridge: Connected, },
      { ..empty_device_state(background), bridge: Connected, },
    ],
  }
  // A settings.changed broadcast from the background device: the form (and
  // the incomplete-settings redirect) keeps the focused host's state.
  let (_, settled) = update(
    dispatch,
    FromDevice(
      background,
      HostSettings(
        Loaded(host_settings(provider="deepseek")),
        connection_generation=None,
      ),
    ),
    model,
  )
  assert_true(settled.host_settings.provider() is Deepseek)
  assert_true(settled.screen is Chat)
}

///|
test "background settings replies cannot alter the focused host mirror" {
  let dispatch = test_dispatch()
  let home = test_model()
  let focused = {
    ..home,
    devices: [
      home.devices[0],
      { ..empty_device_state(Remote("d_b")), bridge: Connected, },
    ],
    focused: Remote("d_b"),
    host_settings: test_host_settings(provider="custom", messages=[
      ProviderChanged("custom"),
    ]),
  }
  let (_, applied) = update(
    dispatch,
    FromDevice(
      Local,
      HostSettings(
        Applied(host_settings(provider="deepseek", revision=7)),
        connection_generation=Some(0),
      ),
    ),
    focused,
  )
  assert_true(applied.host_settings.provider() is Custom)
  assert_eq(applied.host_settings.settings_saves, 1)
  let (_, failed) = update(
    dispatch,
    FromDevice(
      Local,
      HostSettings(SaveFailed("old host failed"), connection_generation=Some(0)),
    ),
    applied,
  )
  assert_eq(failed.host_settings.settings_saves, 1)
  assert_eq(failed.notifications.length(), 0)
}

///|
test "settings readiness supplies the root status and preserves model choice" {
  let official = { ..test_model(), host_settings: test_host_settings(), }
  assert_true(official.display_status() is ApiKeyRequired)
  let custom = {
    ..test_model(),
    host_settings: test_host_settings(provider="custom"),
  }
  assert_true(custom.display_status() is SetupRequired)
  let openrouter = {
    ..test_model(),
    default_model: DsPro,
    host_settings: test_host_settings(
      provider="openrouter",
      has_custom_key=true,
    ),
  }
  assert_true(openrouter.api_ready())
  assert_true(openrouter.default_model is DsPro)
}

///|
test "saving from the setup modal stays on the page it opened over" {
  let model = {
    ..test_model(),
    screen: Skills,
    host_settings: test_host_settings(),
  }
  let (_, typed) = update(
    test_dispatch(),
    HostSettings(SetupApiKeyChanged("sk-test")),
    model,
  )
  let (_, saved) = update(test_dispatch(), HostSettings(SaveApiKey), typed)
  assert_true(saved.screen is Skills)
  assert_false(saved.host_settings.api_setup_open)
  assert_eq(saved.notifications.length(), 0)
  let (_, settings) = update(test_dispatch(), HostSettings(OpenSettings), typed)
  assert_true(settings.screen is Settings)
  assert_eq(settings.host_settings.setup_api_key, "")
  assert_false(settings.host_settings.api_setup_open)
}

///|
test "settled host settings close a modal's menu but preserve a Settings-page menu" {
  let typing = {
    ..test_model(),
    select_menu: Some(ApiProviderMenu),
    host_settings: test_host_settings(provider="custom", messages=[
      CustomApiUrlChanged("https://ok.example/chat"),
    ]),
  }
  let message : DeviceMsg = HostSettings(
    Applied(
      host_settings(
        provider="custom",
        revision=1,
        custom_api_url="https://ok.example/chat",
      ),
    ),
    connection_generation=Some(0),
  )
  let (_, closed) = update_dev(test_dispatch(), message, typing)
  assert_false(closed.host_settings.api_setup_open)
  assert_true(closed.select_menu is None)
  let (_, page) = update(test_dispatch(), HostSettings(OpenSettings), typing)
  let page = { ..page, select_menu: Some(ApiProviderMenu), }
  let (_, settled) = update_dev(test_dispatch(), message, page)
  assert_true(settled.select_menu == Some(ApiProviderMenu))
}

///|
test "old connection settings replies cannot change the current mirror or toast" {
  let model = {
    ..test_model(),
    host_settings: test_host_settings(messages=[ProviderChanged("glm")]),
  }.with_dev(dev => { ..dev, connection_generation: 2, })
  let messages : Array[@host_settings.Msg] = [
    Loaded(host_settings(provider="custom", revision=10)),
    Applied(host_settings(provider="custom", revision=10)),
    SaveFailed("stale failure"),
  ]
  for msg in messages {
    let (_, next) = update_dev(
      test_dispatch(),
      HostSettings(msg, connection_generation=Some(1)),
      model,
    )
    assert_true(next.host_settings == model.host_settings)
    assert_eq(next.notifications.length(), 0)
  }
  let (_, failed) = update_dev(
    test_dispatch(),
    HostSettings(SaveFailed("current failure"), connection_generation=Some(2)),
    model,
  )
  assert_eq(failed.host_settings.settings_saves, 0)
  assert_eq(failed.notifications.length(), 1)
  assert_eq(
    failed.notifications[0].message,
    "Saving settings failed: current failure",
  )
}
