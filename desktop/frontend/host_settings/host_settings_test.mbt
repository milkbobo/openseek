///|
fn status(
  provider~ : String = "deepseek",
  revision~ : Int32 = 0,
  custom_api_url? : String,
  has_deepseek_key~ : Bool = false,
  has_glm_key~ : Bool = false,
  has_custom_key~ : Bool = false,
) -> @protocol.SettingsStatusPayload {
  {
    revision,
    provider,
    custom_api_url,
    has_deepseek_key,
    has_glm_key,
    has_custom_key,
    followup_behavior: "steer",
  }
}

///|
fn send(
  state : @host_settings.State,
  msg : @host_settings.Msg,
  on_settings~ : Bool = false,
) -> (@host_settings.State, Array[@host_settings.Event]) {
  let (next, _, events) = @host_settings.update(
    state,
    msg,
    @cmd.Emit(_ => @cmd.none),
    channel=Local,
    on_settings~,
    locale=English,
  )
  (next, events)
}

///|
fn loaded(payload : @protocol.SettingsStatusPayload) -> @host_settings.State {
  send(@host_settings.State::empty(), Loaded(payload)).0
}

///|
test "the official endpoint requires a key, a custom endpoint a URL" {
  let official = loaded(status())
  assert_false(official.api_ready())
  assert_true(loaded(status(has_deepseek_key=true)).api_ready())
  let glm = loaded(status(provider="glm", has_deepseek_key=true))
  assert_false(glm.api_ready())
  assert_true(loaded(status(provider="glm", has_glm_key=true)).api_ready())
  assert_false(loaded(status(provider="custom")).api_ready())
  assert_true(
    loaded(
      status(
        provider="custom",
        custom_api_url="https://proxy.example/chat/completions",
      ),
    ).api_ready(),
  )
}

///|
test "OpenRouter setup requires only its stored custom key" {
  assert_false(
    loaded(status(provider="openrouter", has_deepseek_key=true)).api_ready(),
  )
  assert_true(
    loaded(status(provider="openrouter", has_custom_key=true)).api_ready(),
  )
}

///|
test "the OpenRouter custom preset restores as OpenRouter" {
  let state = loaded(
    status(
      provider="custom",
      custom_api_url="https://openrouter.ai/api/v1/chat/completions",
      has_custom_key=true,
    ),
  )
  assert_true(state.provider() is OpenRouter)
  assert_true(state.api_ready())
  let (custom, _) = send(state, ProviderChanged("custom"))
  assert_true(custom.provider() is Custom)
  assert_eq(custom.custom_api_url, "")
  assert_false(custom.api_ready())
}

///|
test "host settings edits wait for the focused host snapshot" {
  let old = loaded(
    status(has_deepseek_key=true, custom_api_url="https://old.example/chat"),
  )
  let (old, _) = send(old, SetupApiKeyChanged("old-device-key"))
  let loading = old.clear()
  let messages : Array[@host_settings.Msg] = [
    SetupApiKeyChanged("queued-key"),
    ProviderChanged("custom"),
    CustomApiUrlChanged("https://new.example/chat"),
    SaveApiKey,
    FollowupBehaviorChanged("queue"),
  ]
  for message in messages {
    let (once, events) = send(loading, message)
    let (twice, _) = send(loading, message)
    assert_true(once == loading)
    assert_true(twice == loading)
    assert_eq(events.length(), 0)
  }
}

///|
test "an unusable first settings snapshot opens the setup modal" {
  for provider in ["openseek", "openseek-staging", "deepseek", "unknown"] {
    let (state, events) = send(
      @host_settings.State::empty(),
      Loaded(status(provider~)),
    )
    assert_true(state.api_setup_open)
    assert_true(state.provider() is Deepseek)
    assert_true(events is [AlignProvider])
  }
  assert_false(loaded(status(has_deepseek_key=true)).api_setup_open)
}

///|
test "the setup modal tracks endpoint usability without toasts" {
  let keyless = loaded(status())
  let (ready, events) = send(keyless, Loaded(status(has_deepseek_key=true)))
  assert_false(ready.api_setup_open)
  assert_true(events is [AlignProvider, CloseMenu])
  let (broken, _) = send(ready, Loaded(status(provider="custom")))
  assert_true(broken.api_setup_open)
  let (dismissed, _) = send(broken, DismissApiSetup)
  assert_false(dismissed.api_setup_open)
  let (still, _) = send(dismissed, Loaded(status()))
  assert_false(still.api_setup_open)
  let (settings, events) = send(broken, OpenSettings)
  assert_false(settings.api_setup_open)
  assert_eq(settings.setup_api_key, "")
  assert_true(events is [OpenSettings])
  let (editing, _) = send(
    ready,
    Loaded(status(provider="custom")),
    on_settings=true,
  )
  assert_false(editing.api_setup_open)
}

///|
test "switching to a provider missing its key or URL opens the setup modal" {
  let (switched, events) = send(
    loaded(status(has_deepseek_key=true)),
    ProviderChanged("custom"),
  )
  assert_true(switched.provider() is Custom)
  assert_true(switched.api_setup_open)
  assert_true(events is [CloseMenu, AlignProvider])
  let (back, _) = send(switched, ProviderChanged("deepseek"))
  assert_true(back.provider() is Deepseek)
  assert_false(back.api_setup_open)
  let (kept, _) = send(
    loaded(
      status(
        provider="custom",
        custom_api_url="https://ok.example/chat",
        has_deepseek_key=true,
      ),
    ),
    ProviderChanged("deepseek"),
  )
  assert_false(kept.api_setup_open)
}

///|
test "a dismissal survives the mirror reset a reconnect performs" {
  let (dismissed, _) = send(loaded(status()), DismissApiSetup)
  let cleared = dismissed.clear()
  assert_false(cleared.loaded())
  assert_false(cleared.api_setup_open)
  let (reconnected, _) = send(cleared, Loaded(status()))
  assert_false(reconnected.api_setup_open)
  let (ready, _) = send(reconnected, Loaded(status(has_deepseek_key=true)))
  let (broken, _) = send(ready, Loaded(status()))
  assert_true(broken.api_setup_open)
}

///|
test "reopening cancels a dismissal through later snapshots" {
  let (dismissed, _) = send(loaded(status()), DismissApiSetup)
  let (reopened, _) = send(dismissed, OpenApiSetup)
  assert_true(reopened.api_setup_open)
  let (still, _) = send(reopened, Loaded(status()))
  assert_true(still.api_setup_open)
}

///|
test "a custom endpoint reads as usable only from a plausible URL" {
  for url in ["", "h", "https://", "ftp://host"] {
    assert_false(
      loaded(status(provider="custom", custom_api_url=url)).api_ready(),
    )
  }
  for
    url in [
      "https://host", " https://host/chat/completions ", "http://127.0.0.1:8080",
    ] {
    assert_true(
      loaded(status(provider="custom", custom_api_url=url)).api_ready(),
    )
  }
}

///|
test "clearing the mirror never leaves an orphaned setup modal" {
  let (state, _) = send(loaded(status()), MaxStepsChanged("42"))
  assert_true(state.api_setup_open)
  let cleared = state.clear()
  assert_false(cleared.api_setup_open)
  assert_true(cleared.revision is None)
  assert_eq(cleared.max_steps, "42")
}

///|
test "saving the key from the setup modal retires it" {
  let (typed, _) = send(loaded(status()), SetupApiKeyChanged("sk-test"))
  let (saved, events) = send(typed, SaveApiKey)
  assert_true(saved.deepseek_key_saved)
  assert_false(saved.api_setup_open)
  assert_eq(saved.setup_api_key, "")
  assert_true(events is [CloseMenu])
  let (typed, _) = send(
    loaded(status(provider="custom")),
    SetupApiKeyChanged("sk-custom"),
  )
  let (half, _) = send(typed, SaveApiKey)
  assert_true(half.api_setup_open)
  assert_true(half.custom_key_saved)
}

///|
test "a settled host save that completes the setup closes the modal" {
  let (typing, _) = send(
    loaded(status(provider="custom")),
    CustomApiUrlChanged("https://ok.example/chat"),
  )
  assert_true(typing.api_setup_open)
  let (closed, events) = send(
    typing,
    Applied(
      status(
        provider="custom",
        revision=1,
        custom_api_url="https://ok.example/chat",
      ),
    ),
  )
  assert_false(closed.api_setup_open)
  assert_true(events is [AlignProvider, CloseMenu])
  let (settings, _) = send(typing, OpenSettings)
  let (settled, events) = send(
    settings,
    Applied(
      status(
        provider="custom",
        revision=1,
        custom_api_url="https://ok.example/chat",
      ),
    ),
    on_settings=true,
  )
  assert_false(settled.api_setup_open)
  assert_true(events is [AlignProvider])
  let (incomplete, _) = send(
    typing,
    Applied(status(provider="custom", revision=1)),
  )
  assert_true(incomplete.api_setup_open)
}

///|
test "host settings are deferred while this client's writes are in flight" {
  let (pending, _) = send(
    loaded(status(has_deepseek_key=true)),
    ProviderChanged("deepseek"),
  )
  let (ignored, _) = send(pending, Loaded(status(revision=1)))
  assert_true(ignored.deepseek_key_saved)
  assert_eq(ignored.settings_saves, 1)
  let (settled, _) = send(
    ignored,
    Applied(status(revision=2, has_deepseek_key=true)),
  )
  assert_eq(settled.settings_saves, 0)
  assert_true(settled.deepseek_key_saved)
  assert_true(settled.revision == Some(2))
  let (stacked, _) = send(pending, ProviderChanged("deepseek"))
  let (still, _) = send(stacked, Applied(status(revision=1)))
  assert_eq(still.settings_saves, 1)
  assert_true(still.deepseek_key_saved)
}

///|
test "a newer peer broadcast beats a delayed local settings reply" {
  let (pending, _) = send(
    loaded(status(provider="custom", revision=5)),
    ProviderChanged("custom"),
  )
  let (broadcast, _) = send(pending, Loaded(status(revision=7)))
  assert_true(broadcast.provider() is Custom)
  let (settled, _) = send(
    broadcast,
    Applied(status(provider="openseek", revision=6)),
  )
  assert_true(settled.provider() is Deepseek)
  assert_true(settled.revision == Some(7))
  assert_eq(settled.settings_saves, 0)
  let (stale, events) = send(
    settled,
    Loaded(status(provider="glm", revision=6)),
  )
  assert_true(stale == settled)
  assert_eq(events.length(), 0)
}

///|
test "update is pure: a provider change is idempotent" {
  let (state, _) = send(loaded(status()), SetupApiKeyChanged("typed"))
  let (once, events) = send(state, ProviderChanged("deepseek"))
  let (twice, _) = send(state, ProviderChanged("deepseek"))
  assert_true(once == twice)
  assert_true(once.provider() is Deepseek)
  assert_eq(once.setup_api_key, "")
  assert_eq(once.settings_saves, 1)
  assert_true(events is [CloseMenu, AlignProvider])
  assert_eq(state.setup_api_key, "typed")
  assert_eq(state.settings_saves, 0)
}

///|
test "saving a key marks the active provider credential only" {
  for provider in ["deepseek", "glm", "custom", "openrouter"] {
    let (typed, _) = send(
      loaded(status(provider~)),
      SetupApiKeyChanged("  sk-new  "),
    )
    let (saved, _) = send(typed, SaveApiKey)
    assert_eq(saved.deepseek_key_saved, provider == "deepseek")
    assert_eq(saved.glm_key_saved, provider == "glm")
    assert_eq(
      saved.custom_key_saved,
      provider == "custom" || provider == "openrouter",
    )
    assert_eq(saved.settings_saves, 1)
    assert_eq(saved.setup_api_key, "")
  }
}

///|
test "save failures settle pending revisions and same-revision snapshots restore truth" {
  let (pending, _) = send(
    loaded(status(revision=5, has_deepseek_key=true)),
    ProviderChanged("glm"),
  )
  let (pending, _) = send(pending, CustomApiUrlChanged("https://host"))
  let (deferred, _) = send(pending, Loaded(status(revision=6)))
  let (first, events) = send(deferred, SaveFailed("first"))
  assert_eq(first.settings_saves, 1)
  assert_true(first.provider() is Glm)
  assert_true(events is [Problem("Saving settings failed: first")])
  let (last, events) = send(first, SaveFailed("last"))
  assert_eq(last.settings_saves, 0)
  assert_true(last.provider() is Deepseek)
  assert_true(last.revision == Some(6))
  assert_true(
    events is [AlignProvider, Problem("Saving settings failed: last")],
  )
  let (optimistic, _) = send(last, ProviderChanged("glm"))
  let (failed, _) = send(optimistic, SaveFailed("lost reply"))
  let (restored, _) = send(failed, Loaded(status(revision=6)))
  assert_true(restored.provider() is Deepseek)
  assert_eq(restored.settings_saves, 0)
}

///|
test "blank keys do not save and followup settings report menu closure" {
  let (blank, _) = send(loaded(status()), SetupApiKeyChanged("  "))
  let (saved, events) = send(blank, SaveApiKey)
  assert_true(saved == blank)
  assert_eq(events.length(), 0)
  let (queue, events) = send(blank, FollowupBehaviorChanged("queue"))
  assert_true(queue.followup_behavior is FollowupQueue)
  assert_eq(queue.settings_saves, 1)
  assert_true(events is [CloseMenu])
}
