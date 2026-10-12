///|
test "the official endpoint requires a key, a custom endpoint a URL" {
  let official = {
    ..test_model(),
    api_provider: Deepseek,
    deepseek_key_saved: false,
  }
  assert_false(official.api_ready())
  assert_true(official.display_status() is ApiKeyRequired)
  assert_true({ ..official, deepseek_key_saved: true, }.api_ready())
  // The GLM provider is gated on its own key, never DeepSeek's.
  let glm = {
    ..test_model(),
    api_provider: Glm,
    deepseek_key_saved: true,
    glm_key_saved: false,
  }
  assert_false(glm.api_ready())
  assert_true(glm.display_status() is ApiKeyRequired)
  assert_true({ ..glm, glm_key_saved: true, }.api_ready())
  let custom = { ..test_model(), api_provider: Custom, custom_api_url: "", }
  assert_false(custom.api_ready())
  assert_true(custom.display_status() is SetupRequired)
  let configured = {
    ..custom,
    custom_api_url: "https://proxy.example/chat/completions",
  }
  assert_true(configured.api_ready())
}

///|
test "OpenRouter setup requires only its stored custom key" {
  let openrouter = {
    ..test_model(),
    api_provider: OpenRouter,
    deepseek_key_saved: true,
    custom_key_saved: false,
  }
  assert_false(openrouter.api_ready())
  assert_true({ ..openrouter, custom_key_saved: true, }.api_ready())
  // Model choice belongs to the chat, just as with the official endpoint.
  assert_true(
    { ..openrouter, custom_key_saved: true, default_model: DsPro, }.api_ready(),
  )
}

///|
test "the OpenRouter custom preset restores as OpenRouter" {
  let restored = test_model().apply_host_settings(
    host_settings(
      provider="custom",
      custom_api_url=OpenRouterChatCompletionsUrl,
      has_custom_key=true,
    ),
  )
  assert_true(restored.api_provider is OpenRouter)
  assert_true(restored.api_ready())
}

///|
test "host settings edits wait for the focused host snapshot" {
  let dispatch = test_dispatch()
  // Model a queued DOM message from the old Settings page after focus already
  // moved. The negative revision is authoritative: none of these stale values
  // or events may be applied to the replacement host.
  let loading = {
    ..test_model(),
    api_provider: Deepseek,
    custom_api_url: "https://old.example/chat",
    deepseek_key_saved: true,
    setup_api_key: "old-device-key",
    host_settings_revision: -1,
  }
  let messages : Array[Msg] = [
    SetupApiKeyChanged("queued-key"),
    ProviderChanged("custom"),
    CustomApiUrlChanged("https://new.example/chat"),
    SaveApiKey,
  ]
  for message in messages {
    let (_, once) = update(dispatch, message, loading)
    let (_, twice) = update(dispatch, message, loading)
    assert_true(once.api_provider == loading.api_provider)
    assert_eq(once.custom_api_url, loading.custom_api_url)
    assert_eq(once.setup_api_key, loading.setup_api_key)
    assert_eq(once.settings_saves, 0)
    assert_true(twice.api_provider == loading.api_provider)
    assert_eq(twice.custom_api_url, loading.custom_api_url)
    assert_eq(twice.setup_api_key, loading.setup_api_key)
    assert_eq(twice.settings_saves, 0)
  }
}

///|
test "an unusable first settings snapshot opens the setup modal" {
  let dispatch = test_dispatch()
  // A hosted-provider value left by an older build parses as the BYOK
  // default: keyless DeepSeek, which needs setup.
  let (_, zero_config) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="openseek"),
      connection_generation=None,
    ),
    test_model(),
  )
  assert_true(zero_config.screen is Chat)
  assert_true(zero_config.api_setup_open)
  assert_true(zero_config.api_provider is Deepseek)
  assert_true(zero_config.display_status() is ApiKeyRequired)
  let (_, keyless) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    test_model(),
  )
  assert_true(keyless.screen is Chat)
  assert_true(keyless.api_setup_open)
  assert_true(keyless.display_status() is ApiKeyRequired)
  let (_, restored) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek", has_deepseek_key=true),
      connection_generation=None,
    ),
    test_model(),
  )
  assert_true(restored.screen is Chat)
  assert_true(!restored.api_setup_open)
  assert_true(restored.deepseek_key_saved)
}

///|
test "the setup modal tracks endpoint usability without toasts" {
  let dispatch = test_dispatch()
  let (_, keyless) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    test_model(),
  )
  assert_true(keyless.api_setup_open)
  // The modal is the announcement; a toast under it would double-signal.
  assert_eq(keyless.notifications.length(), 0)
  // A snapshot that is usable closes the modal.
  let (_, ready) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek", has_deepseek_key=true),
      connection_generation=None,
    ),
    { ..test_model(), api_setup_open: true, },
  )
  assert_true(!ready.api_setup_open)
  assert_eq(ready.notifications.length(), 0)
  // A later change that breaks a usable endpoint reopens the modal.
  let (_, broken) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="custom", custom_api_url=""),
      connection_generation=None,
    ),
    {
      ..test_model(),
      host_settings_revision: 0,
      api_provider: Custom,
      custom_api_url: "https://ok.example/chat",
    },
  )
  assert_true(broken.api_setup_open)
  // "Not now" dismisses; an unrelated payload that leaves the endpoint
  // unusable does not re-announce it.
  let (_, dismissed) = update(dispatch, DismissApiSetup, {
    ..broken,
    api_setup_open: true,
  })
  assert_true(!dismissed.api_setup_open)
  let (_, still) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    dismissed,
  )
  assert_true(!still.api_setup_open)
  // Opening Settings from the gear closes the modal.
  let (_, on_settings) = update(dispatch, OpenSetup, {
    ..broken,
    api_setup_open: true,
  })
  assert_true(on_settings.screen is Settings)
  assert_true(!on_settings.api_setup_open)
  // Breaking while the Settings page is open does not pop the modal over
  // the form; the guide there already explains it.
  let (_, mid_edit) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="custom", custom_api_url=""),
      connection_generation=None,
    ),
    {
      ..test_model(),
      screen: Settings,
      host_settings_revision: 0,
      api_provider: Custom,
      custom_api_url: "https://ok.example/chat",
    },
  )
  assert_true(!mid_edit.api_setup_open)
}

///|
test "switching to a provider missing its key or URL opens the setup modal" {
  let dispatch = test_dispatch()
  // The BYOK fixture is ready (a key is saved); switching to Custom with
  // no URL takes the endpoint from usable to not. Off the Settings page
  // the setup modal is the announcement — no toast underneath it.
  let (_, switched) = update(dispatch, ProviderChanged("custom"), test_model())
  assert_true(switched.api_provider is Custom)
  assert_true(switched.api_setup_open)
  assert_eq(switched.notifications.length(), 0)
  // A switch that stays usable stays quiet.
  let (_, kept) = update(dispatch, ProviderChanged("deepseek"), {
    ..test_model(),
    api_provider: Custom,
    custom_api_url: "https://ok.example/chat",
  })
  assert_true(!kept.api_setup_open)
  // Switching back to a provider the stored key makes usable retires the
  // modal that the break opened.
  let (_, back) = update(dispatch, ProviderChanged("deepseek"), switched)
  assert_true(back.api_provider is Deepseek)
  assert_true(!back.api_setup_open)
}

///|
test "the GLM provider aligns only a fresh chat to its model family" {
  let dispatch = test_dispatch()
  let (_, glm) = update(dispatch, ProviderChanged("glm"), {
    ..test_model(),
    glm_key_saved: true,
  })
  assert_true(glm.api_provider is Glm)
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
    HostSettingsLoaded(
      host_settings(provider="glm", has_glm_key=true),
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
  let (_, running) = update(dispatch, ProviderChanged("glm"), running_model())
  assert_true(running.api_provider is Glm)
  assert_true(running.default_model is Glm53)
  assert_true(running.active().engine_model is DsPro)
  assert_true(running.display_status() is Running)
}

///|
test "a dismissal survives the mirror reset a reconnect performs" {
  let dispatch = test_dispatch()
  let (_, keyless) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    test_model(),
  )
  let (_, dismissed) = update(dispatch, DismissApiSetup, keyless)
  // A reconnect (or focus switch) resets the mirror to the loading
  // sentinel; the refetched snapshot must not re-pop the modal on every
  // WS flap — dismissal is the user's answer for the session.
  let cleared = dismissed.clear_host_settings()
  assert_true(!cleared.api_setup_open)
  let (_, reconnected) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    cleared,
  )
  assert_true(!reconnected.api_setup_open)
  // A usable endpoint re-arms the announcement: the next break prompts
  // again even after an earlier "Not now".
  let (_, ready) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek", has_deepseek_key=true),
      connection_generation=None,
    ),
    reconnected,
  )
  assert_true(!ready.api_setup_open)
  let (_, broken) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    ready,
  )
  assert_true(broken.api_setup_open)
}

///|
test "the composer's BYOK notice outlives a dismissal and reopens the modal" {
  let dispatch = test_dispatch()
  let (_, keyless) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    test_model(),
  )
  let (_, dismissed) = update(dispatch, DismissApiSetup, keyless)
  // Quiet must not mean lost: the notice stays while the endpoint is
  // unusable, dismissal or not.
  assert_true(dismissed.api_setup_banner_visible())
  // The loading sentinel is not a verdict; a reconnect must not flash it.
  assert_true(!dismissed.clear_host_settings().api_setup_banner_visible())
  // A usable endpoint retires the notice with the modal.
  assert_true(!test_model().api_setup_banner_visible())
  // Its "Set up" reopens the modal, and reopening cancels the dismissal so
  // the next settled snapshot leaves the modal the user asked for alone.
  let (_, reopened) = update(dispatch, OpenApiSetup, dismissed)
  assert_true(reopened.api_setup_open)
  let (_, still_open) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek"),
      connection_generation=None,
    ),
    reopened,
  )
  assert_true(still_open.api_setup_open)
}

///|
test "a custom endpoint reads as usable only from a plausible URL" {
  let custom = {
    ..test_model(),
    api_provider: Custom,
    deepseek_key_saved: false,
  }
  // A prefix mid-typing must not arm Send or retire the setup modal.
  assert_true(!{ ..custom, custom_api_url: "", }.api_ready())
  assert_true(!{ ..custom, custom_api_url: "h", }.api_ready())
  assert_true(!{ ..custom, custom_api_url: "https://", }.api_ready())
  assert_true(!{ ..custom, custom_api_url: "ftp://host", }.api_ready())
  assert_true({ ..custom, custom_api_url: "https://host", }.api_ready())
  assert_true(
    { ..custom, custom_api_url: " https://host/chat/completions ", }.api_ready(),
  )
  assert_true(
    { ..custom, custom_api_url: "http://127.0.0.1:8080", }.api_ready(),
  )
}

///|
test "clearing the mirror never leaves an orphaned setup modal" {
  // A modal left up over the loading sentinel would render default data
  // with every control disabled; close it with the mirror it was showing.
  let open = {
    ..test_model(),
    api_setup_open: true,
    deepseek_key_saved: false,
  }
  assert_true(!open.clear_host_settings().api_setup_open)
}

///|
test "saving from the setup modal stays on the page it opened over" {
  let dispatch = test_dispatch()
  // The modal renders over any screen; completing setup from it must not
  // yank the user to Chat.
  let over_skills = {
    ..test_model(),
    screen: Skills,
    api_setup_open: true,
    deepseek_key_saved: false,
  }
  let (_, typed) = update(dispatch, SetupApiKeyChanged("sk-test"), over_skills)
  let (_, saved) = update(dispatch, SaveApiKey, typed)
  assert_true(saved.screen is Skills)
  assert_true(!saved.api_setup_open)
  // A save that leaves the setup incomplete (Custom, no URL yet) keeps the
  // modal up mid-setup instead of dumping the user on Settings.
  let custom_half = {
    ..test_model(),
    api_provider: Custom,
    custom_api_url: "",
    api_setup_open: true,
  }
  let (_, keyed) = update(
    dispatch,
    SetupApiKeyChanged("sk-custom"),
    custom_half,
  )
  let (_, still_open) = update(dispatch, SaveApiKey, keyed)
  assert_true(still_open.screen is Chat)
  assert_true(still_open.api_setup_open)
}

///|
test "saving the key from the setup modal retires it" {
  let dispatch = test_dispatch()
  let open = {
    ..test_model(),
    api_setup_open: true,
    deepseek_key_saved: false,
  }
  let (_, typed) = update(dispatch, SetupApiKeyChanged("sk-test"), open)
  let (_, saved) = update(dispatch, SaveApiKey, typed)
  assert_true(saved.deepseek_key_saved)
  assert_true(saved.screen is Chat)
  assert_true(!saved.api_setup_open)
  assert_eq(saved.setup_api_key, "")
}

///|
test "a settled host save that completes the setup closes the modal" {
  // A custom URL typed into the modal is saved optimistically; the host's
  // applied confirmation is what retires the modal, not mid-typing.
  let typing = {
    ..test_model(),
    api_setup_open: true,
    api_provider: Custom,
    custom_api_url: "https://ok.example/chat",
    settings_saves: 1,
    select_menu: Some(ApiProviderMenu),
  }
  let closed = typing.flush_host_settings()
  assert_true(!closed.api_setup_open)
  assert_true(closed.select_menu is None)
  // The same host reconciliation must not close the API selector when it is
  // owned by the Settings page rather than an open setup modal.
  let page = {
    ..typing,
    screen: Settings,
    api_setup_open: false,
    select_menu: Some(ApiProviderMenu),
  }.flush_host_settings()
  assert_true(page.select_menu == Some(ApiProviderMenu))
  // A flush that leaves the endpoint unusable keeps the modal up.
  let still = {
    ..test_model(),
    api_setup_open: true,
    api_provider: Deepseek,
    deepseek_key_saved: false,
    deferred_host_settings: Some(host_settings(provider="deepseek")),
    host_settings_revision: -1,
  }
  assert_true(still.flush_host_settings().api_setup_open)
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
      HostSettingsLoaded(
        host_settings(provider="deepseek"),
        connection_generation=None,
      ),
    ),
    model,
  )
  assert_true(settled.api_provider is Deepseek)
  assert_true(settled.screen is Chat)
}

///|
test "host settings are deferred while this client's writes are in flight" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), settings_saves: 1, }
  // A broadcast (or a stale get reply) arriving mid-write must not clobber
  // the optimistic mirror.
  let (_, ignored) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek", revision=1),
      connection_generation=None,
    ),
    model,
  )
  assert_true(ignored.api_provider is Deepseek)
  inspect(ignored.settings_saves, content="1")
  // The write's own reply reconciles once it is the last one out.
  let (_, settled) = update_dev(
    dispatch,
    HostSettingsApplied(
      host_settings(provider="deepseek", revision=2, has_deepseek_key=true),
      connection_generation=0,
    ),
    model,
  )
  inspect(settled.settings_saves, content="0")
  assert_true(settled.api_provider is Deepseek)
  assert_true(settled.deepseek_key_saved)
  inspect(settled.host_settings_revision, content="2")
  // With more writes still out, even a reply only decrements.
  let stacked = { ..model, settings_saves: 2, }
  let (_, still_pending) = update_dev(
    dispatch,
    HostSettingsApplied(
      host_settings(provider="deepseek", revision=1),
      connection_generation=0,
    ),
    stacked,
  )
  inspect(still_pending.settings_saves, content="1")
  assert_true(still_pending.api_provider is Deepseek)
}

///|
test "a newer peer broadcast beats a delayed local settings reply" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    api_provider: Custom,
    settings_saves: 1,
    host_settings_revision: 5,
  }
  let (_, broadcast) = update_dev(
    dispatch,
    HostSettingsLoaded(
      host_settings(provider="deepseek", revision=7),
      connection_generation=None,
    ),
    model,
  )
  // Preserve the optimistic form until the local RPC settles.
  assert_true(broadcast.api_provider is Custom)
  let (_, settled) = update_dev(
    dispatch,
    HostSettingsApplied(
      host_settings(provider="openseek", revision=6),
      connection_generation=0,
    ),
    broadcast,
  )
  assert_true(settled.api_provider is Deepseek)
  inspect(settled.host_settings_revision, content="7")
  inspect(settled.settings_saves, content="0")
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
    api_provider: Custom,
    settings_saves: 1,
  }
  let (_, applied) = update(
    dispatch,
    FromDevice(
      Local,
      HostSettingsApplied(
        host_settings(provider="deepseek", revision=7),
        connection_generation=0,
      ),
    ),
    focused,
  )
  assert_true(applied.api_provider is Custom)
  assert_eq(applied.settings_saves, 1)
  let (_, failed) = update(
    dispatch,
    FromDevice(
      Local,
      HostSettingsSaveFailed("old host failed", connection_generation=0),
    ),
    applied,
  )
  assert_eq(failed.settings_saves, 1)
  assert_eq(failed.notifications.length(), 0)
}

///|
test "update is pure: a provider change is idempotent" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    setup_api_key: "typed",
    deepseek_key_saved: false,
  }
  let (_, once) = update(dispatch, ProviderChanged("deepseek"), model)
  let (_, twice) = update(dispatch, ProviderChanged("deepseek"), model)
  assert_true(once.api_provider is Deepseek)
  assert_true(twice.api_provider is Deepseek)
  inspect(once.setup_api_key, content="")
  inspect(twice.setup_api_key, content="")
  inspect(once.settings_saves, content="1")
  inspect(twice.settings_saves, content="1")
  assert_true(once.display_status() is ApiKeyRequired)
  assert_true(twice.display_status() is ApiKeyRequired)
}

///|
test "saving a key marks the active provider credential only" {
  let dispatch = test_dispatch()
  let deepseek = {
    ..test_model(),
    api_provider: Deepseek,
    deepseek_key_saved: false,
    setup_api_key: "  sk-new  ",
    screen: Settings,
  }
  let (_, saved_deepseek) = update(dispatch, SaveApiKey, deepseek)
  assert_true(saved_deepseek.deepseek_key_saved)
  assert_false(saved_deepseek.custom_key_saved)
  inspect(saved_deepseek.setup_api_key, content="")
  inspect(saved_deepseek.settings_saves, content="1")
  // The save never navigates: a key saved on the Settings page leaves the
  // user on the form they were filling in.
  assert_true(saved_deepseek.screen is Settings)
  // Each provider's flag is independent: switching to Custom and saving
  // marks only the custom credential.
  let custom = {
    ..test_model(),
    api_provider: Custom,
    deepseek_key_saved: false,
    custom_api_url: "https://proxy.example/chat/completions",
    setup_api_key: "  sk-custom-new  ",
    screen: Settings,
  }
  let (_, saved_custom) = update(dispatch, SaveApiKey, custom)
  assert_false(saved_custom.deepseek_key_saved)
  assert_true(saved_custom.custom_key_saved)
  assert_true(saved_custom.screen is Settings)
  // A GLM key lands in the GLM slot alone.
  let glm = {
    ..test_model(),
    api_provider: Glm,
    deepseek_key_saved: false,
    glm_key_saved: false,
    setup_api_key: "  glm-new  ",
    screen: Settings,
  }
  let (_, saved_glm) = update(dispatch, SaveApiKey, glm)
  assert_true(saved_glm.glm_key_saved)
  assert_false(saved_glm.deepseek_key_saved)
  assert_false(saved_glm.custom_key_saved)
  assert_true(saved_glm.screen is Settings)
  let openrouter = {
    ..test_model(),
    api_provider: OpenRouter,
    deepseek_key_saved: false,
    custom_key_saved: false,
    setup_api_key: "  sk-openrouter-new  ",
    screen: Settings,
  }
  let (_, saved_openrouter) = update(dispatch, SaveApiKey, openrouter)
  assert_true(saved_openrouter.custom_key_saved)
  assert_false(saved_openrouter.deepseek_key_saved)
}
