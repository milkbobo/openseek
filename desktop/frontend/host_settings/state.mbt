///|
/// The focused host's settings mirror and the page-local setup form.
/// None means this connection has not supplied a settings snapshot yet.
pub struct State {
  max_steps : String
  priv api_provider : ApiProvider
  // Editable form text: an empty value clears the host endpoint.
  custom_api_url : String
  deepseek_key_saved : Bool
  glm_key_saved : Bool
  custom_key_saved : Bool
  // Unsaved form text only; host replies carry credential presence.
  setup_api_key : String
  followup_behavior : FollowupBehavior
  // Hold the optimistic form until every outstanding write settles.
  settings_saves : Int32
  revision : Int32?
  priv deferred : @protocol.SettingsStatusPayload?
  api_setup_open : Bool
  priv api_setup_dismissed : Bool
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
pub fn State::empty() -> State {
  {
    max_steps: "1000",
    api_provider: Deepseek,
    custom_api_url: "",
    deepseek_key_saved: false,
    glm_key_saved: false,
    custom_key_saved: false,
    setup_api_key: "",
    followup_behavior: FollowupSteer,
    settings_saves: 0,
    revision: None,
    deferred: None,
    api_setup_open: false,
    api_setup_dismissed: false,
  }
}

///|
pub fn State::provider(self : State) -> ApiProvider {
  self.api_provider
}

///|
pub fn State::loaded(self : State) -> Bool {
  self.revision is Some(_)
}

///|
/// Forget the old device's mirror; keep page-local step limit and dismissal.
pub fn State::clear(self : State) -> State {
  {
    ..State::empty(),
    max_steps: self.max_steps,
    api_setup_dismissed: self.api_setup_dismissed,
  }
}

///|
pub(all) enum Msg {
  MaxStepsChanged(String)
  SetupApiKeyChanged(String)
  ProviderChanged(String)
  FollowupBehaviorChanged(String)
  CustomApiUrlChanged(String)
  SaveApiKey
  DismissApiSetup
  OpenApiSetup
  OpenSettings
  OpenExternal(String)
  Loaded(@protocol.SettingsStatusPayload)
  Applied(@protocol.SettingsStatusPayload)
  SaveFailed(String)
}

///|
pub(all) enum Event {
  AlignProvider
  CloseMenu
  OpenSettings
  OpenExternal(String)
  Problem(String)
}

///|
fn State::apply(
  self : State,
  settings : @protocol.SettingsStatusPayload,
) -> State {
  let custom_api_url = settings.custom_api_url.unwrap_or("")
  let provider = if settings.provider == "custom" &&
    custom_api_url == OpenRouterChatCompletionsUrl {
    OpenRouter
  } else {
    ApiProvider::parse(settings.provider)
  }
  {
    ..self,
    revision: Some(settings.revision),
    deferred: None,
    api_provider: provider,
    custom_api_url,
    followup_behavior: FollowupBehavior::parse(settings.followup_behavior),
    deepseek_key_saved: settings.has_deepseek_key,
    glm_key_saved: settings.has_glm_key,
    custom_key_saved: settings.has_custom_key,
  }
}

///|
fn State::older(
  self : State,
  settings : @protocol.SettingsStatusPayload,
) -> Bool {
  self.revision is Some(revision) && settings.revision < revision
}

///|
/// Keep the newest revision while writes are outstanding, regardless of
/// whether it arrived in a broadcast or an individual request's reply.
fn State::defer_settings(
  self : State,
  settings : @protocol.SettingsStatusPayload,
) -> State {
  if self.older(settings) {
    return self
  }
  let deferred = match self.deferred {
    Some(current) if current.revision > settings.revision => current
    _ => settings
  }
  { ..self, deferred: Some(deferred), }
}

///|
/// Retire menus only when an open modal actually closes. A Settings-page
/// selector shares that identity and must survive unrelated snapshots.
fn State::settle(self : State, on_settings~ : Bool) -> (State, Array[Event]) {
  guard self.loaded() else { return (self, []) }
  if self.api_ready() {
    (
      { ..self, api_setup_open: false, api_setup_dismissed: false, },
      if self.api_setup_open {
        [CloseMenu]
      } else {
        []
      },
    )
  } else if self.api_setup_dismissed || on_settings {
    (
      { ..self, api_setup_open: false, },
      if self.api_setup_open {
        [CloseMenu]
      } else {
        []
      },
    )
  } else {
    ({ ..self, api_setup_open: true, }, [])
  }
}

///|
/// Equal revisions are accepted so an authoritative get can restore a
/// failed optimistic edit even when the host did not write anything.
fn State::flush(self : State, on_settings~ : Bool) -> (State, Array[Event]) {
  let (next, events) = match self.deferred {
    Some(settings) if !self.older(settings) =>
      (self.apply(settings), [AlignProvider])
    _ => ({ ..self, deferred: None, }, [])
  }
  let (next, settled) = next.settle(on_settings~)
  (next, [..events, ..settled])
}

///|
/// The root supplies an emit fenced to the requesting device and connection.
/// All bridge work stays deferred in Cmd; the state transition is pure.
pub fn update(
  state : State,
  msg : Msg,
  emit : @cmd.Emit[Msg],
  channel~ : @interop.ChannelId,
  on_settings~ : Bool,
  locale~ : @i18n.Locale,
) -> (State, @cmd.Cmd, Array[Event]) {
  match msg {
    MaxStepsChanged(value) => ({ ..state, max_steps: value, }, @cmd.none, [])
    SetupApiKeyChanged(value) => {
      guard state.loaded() else { return (state, @cmd.none, []) }
      ({ ..state, setup_api_key: value, }, @cmd.none, [])
    }
    ProviderChanged(value) => {
      guard state.loaded() else { return (state, @cmd.none, []) }
      let provider = ApiProvider::parse(value)
      let command = push_settings(
        emit,
        channel,
        provider_settings_patch(provider, state.custom_api_url),
      )
      let next = {
        ..state,
        api_provider: provider,
        custom_api_url: if provider is Custom &&
          state.custom_api_url == OpenRouterChatCompletionsUrl {
          ""
        } else {
          state.custom_api_url
        },
        setup_api_key: "",
        settings_saves: state.settings_saves + 1,
      }
      let (next, events) = next.settle(on_settings~)
      (next, command, [CloseMenu, AlignProvider, ..events])
    }
    FollowupBehaviorChanged(value) => {
      guard state.loaded() else { return (state, @cmd.none, []) }
      let behavior = FollowupBehavior::parse(value)
      (
        {
          ..state,
          followup_behavior: behavior,
          settings_saves: state.settings_saves + 1,
        },
        push_settings(emit, channel, followup_behavior_patch(behavior)),
        [CloseMenu],
      )
    }
    CustomApiUrlChanged(value) => {
      guard state.loaded() else { return (state, @cmd.none, []) }
      (
        {
          ..state,
          custom_api_url: value,
          settings_saves: state.settings_saves + 1,
        },
        push_settings(emit, channel, custom_url_settings_patch(value)),
        [],
      )
    }
    SaveApiKey => {
      guard state.loaded() else { return (state, @cmd.none, []) }
      let api_key = state.setup_api_key.trim().to_owned()
      guard !api_key.is_empty() else { return (state, @cmd.none, []) }
      let provider = state.api_provider
      let next = {
        ..state,
        deepseek_key_saved: state.deepseek_key_saved || provider is Deepseek,
        glm_key_saved: state.glm_key_saved || provider is Glm,
        custom_key_saved: state.custom_key_saved ||
        provider is (OpenRouter | Custom),
        setup_api_key: "",
        settings_saves: state.settings_saves + 1,
      }
      let (next, events) = next.settle(on_settings~)
      (
        next,
        push_settings(emit, channel, api_key_settings_patch(provider, api_key)),
        events,
      )
    }
    DismissApiSetup =>
      (
        { ..state, api_setup_open: false, api_setup_dismissed: true, },
        @cmd.none,
        [],
      )
    OpenApiSetup =>
      (
        { ..state, api_setup_open: true, api_setup_dismissed: false, },
        @cmd.none,
        [],
      )
    OpenSettings =>
      (
        { ..state, setup_api_key: "", api_setup_open: false, },
        @cmd.none,
        [OpenSettings],
      )
    OpenExternal(url) => (state, @cmd.none, [OpenExternal(url)])
    Loaded(settings) =>
      if state.older(settings) {
        (state, @cmd.none, [])
      } else if state.settings_saves > 0 {
        (state.defer_settings(settings), @cmd.none, [])
      } else {
        let (next, events) = state.apply(settings).settle(on_settings~)
        (next, @cmd.none, [AlignProvider, ..events])
      }
    Applied(settings) => {
      let next = {
        ..state,
        settings_saves: if state.settings_saves > 0 {
          state.settings_saves - 1
        } else {
          0
        },
      }.defer_settings(settings)
      if next.settings_saves > 0 {
        (next, @cmd.none, [])
      } else {
        let (next, events) = next.flush(on_settings~)
        (next, @cmd.none, events)
      }
    }
    SaveFailed(message) => {
      // The last failed write may have no successful reply after it. Refetch
      // host truth once the remaining optimistic writes have settled.
      let next = {
        ..state,
        settings_saves: if state.settings_saves > 0 {
          state.settings_saves - 1
        } else {
          0
        },
      }
      let (next, events) = if next.settings_saves == 0 {
        next.flush(on_settings~)
      } else {
        (next, [])
      }
      (
        next,
        if next.settings_saves == 0 {
          fetch_status(emit, channel)
        } else {
          @cmd.none
        },
        [..events, Problem(text(locale, SaveSettings(message)))],
      )
    }
  }
}

///|
/// Whether the configured endpoint is usable as it stands: keyed providers
/// need their own credential, and a custom endpoint needs a plausible URL.
/// OpenRouter uses the same model selector as the official DeepSeek endpoint.
/// The credentials themselves live on the host; a start carries none.
pub fn State::api_ready(self : State) -> Bool {
  match self.api_provider {
    Deepseek => self.deepseek_key_saved
    Glm => self.glm_key_saved
    OpenRouter => self.custom_key_saved
    Custom => plausible_endpoint_url(self.custom_api_url)
  }
}

///|
/// Whether a custom endpoint URL is complete enough to try: an http(s)
/// scheme followed by at least one host character. The URL is pushed to the
/// host per keystroke, so a prefix the user is still typing must not read
/// as usable — that would retire the setup modal mid-word and arm Send
/// against an endpoint every run fails on.
fn plausible_endpoint_url(url : String) -> Bool {
  url.trim() =~ re"^https?://[^/]"
}
