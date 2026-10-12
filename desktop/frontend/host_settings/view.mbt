///|
using @icons {icon, icon_link_external}

///|
fn provider_hint(locale : @i18n.Locale, provider : ApiProvider) -> String {
  match provider {
    Deepseek => @settings.text(locale, DeepseekHint)
    Glm => @settings.text(locale, GlmHint)
    OpenRouter => @settings.text(locale, OpenRouterHint)
    Custom => @settings.text(locale, CustomHint)
  }
}

///|
/// The bring-your-own-key guide shown at the top of the API group while the
/// configured endpoint is not usable. SeekMoon ships no hosted API: every
/// request goes straight from this machine to the user's own model
/// provider, so a key (official) or an endpoint URL (custom) must be
/// configured first. The steps follow the selected provider.
fn byok_setup_guide(
  dispatch : @cmd.Emit[Msg],
  state : State,
  locale : @i18n.Locale,
  is_desktop~ : Bool,
) -> @html.Html {
  let provider = state.api_provider
  // Account setup belongs in the user's system browser, even while this
  // guide is displayed over Chat. Bypass Rabbita's dock URL routing.
  let provider_link = (url, label) => {
    @html.a(
      class="button secondary setting-link",
      href=url,
      target=Blank,
      rel="noopener noreferrer",
      escape=true,
      attrs=@html.Attrs::build().on_click(event => {
        if is_desktop {
          event.prevent_default()
          dispatch(OpenExternal(url))
        } else {
          @cmd.none
        }
      }),
      [icon(icon_link_external), @html.span(label)],
    )
  }
  let step : (Int32, String) -> @html.Html = (index, text) => {
    @html.div(class="setup-guide-step", [
      @html.span(class="setup-guide-index", index.to_string()),
      @html.span(class="setup-guide-text", text),
    ])
  }
  let steps : Array[@html.Html] = match provider {
    Deepseek =>
      [
        step(1, @settings.text(locale, DeepseekStepOne)),
        step(2, @settings.text(locale, CreateKey)),
        step(3, @settings.text(locale, DeepseekPasteKey)),
      ]
    Glm =>
      [
        step(1, @settings.text(locale, GlmStepOne)),
        step(2, @settings.text(locale, CreateKey)),
        step(3, @settings.text(locale, GlmPasteKey)),
      ]
    OpenRouter =>
      [
        step(1, @settings.text(locale, OpenRouterStepOne)),
        step(2, @settings.text(locale, OpenRouterPasteKey)),
      ]
    Custom =>
      [
        step(1, @settings.text(locale, StartEndpoint)),
        step(2, @settings.text(locale, EnterEndpoint)),
        step(3, @settings.text(locale, OptionalEndpointKey)),
      ]
  }
  @html.div(
    class="setup-guide",
    [
      @html.p(@settings.text(locale, OwnProviderDescription)),
      @html.div(class="setup-guide-steps", steps),
      ..if provider is Deepseek {
        [
          provider_link(
            "https://platform.deepseek.com/api_keys",
            @settings.text(locale, DeepseekKeysLink),
          ),
        ]
      },
      ..if provider is Glm {
        [
          provider_link(
            "https://z.ai/manage-apikey/apikey-list",
            @settings.text(locale, GlmKeysLink),
          ),
        ]
      },
    ],
  )
}

///|
/// The API configuration rows shared by the Settings page and the API-setup
/// modal: the BYOK guide while the endpoint is unusable, the provider
/// selector, and the endpoint URL / API key fields that complete the setup.
/// The modal is this same section lifted out of the page, so setup happens
/// in place instead of a navigation.
pub fn api_settings_rows(
  dispatch : @cmd.Emit[Msg],
  state : State,
  locale : @i18n.Locale,
  is_desktop~ : Bool,
  menu~ : Menu,
) -> Array[@html.Html] {
  let settings_loaded = state.loaded()
  let ready = state.api_ready()
  let rows : Array[@html.Html] = [
    ..if !ready {
      [byok_setup_guide(dispatch, state, locale, is_desktop~)]
    },
    @settings.row(
      @settings.text(locale, ApiEndpoint),
      [
        menu.control(
          id="api-provider-select",
          options=[
            {
              value: "deepseek",
              label: @settings.text(locale, DeepseekOfficial),
            },
            { value: "glm", label: @settings.text(locale, GlmOfficial), },
            { value: "openrouter", label: "OpenRouter", },
            { value: "custom", label: @settings.text(locale, CustomUrl), },
          ],
          selected=state.api_provider.wire(),
          aria_label=@settings.text(locale, ApiEndpoint),
          change=dispatch.map(value => ProviderChanged(value)),
          disabled=!settings_loaded,
        ),
      ],
      desc=provider_hint(locale, state.api_provider),
    ),
  ]
  if state.api_provider is Custom {
    rows.push(
      @settings.row(
        @settings.text(locale, EndpointUrl),
        [
          @html.input(
            input_type=@html.InputType::Text,
            value=state.custom_api_url,
            placeholder="https://host/chat/completions",
            on_input=dispatch.map(value => CustomApiUrlChanged(value)),
            attrs=@html.Attrs::build()
              .aria_label(@settings.text(locale, EndpointUrl))
              .data_set("focus-owner", "")
              .disabled(!settings_loaded),
          ),
        ],
        stack=true,
      ),
    )
  }
  // The key lives on the host and is never echoed back — the page only
  // knows one is saved; saving a new one overwrites it.
  {
    let (key_label, key_saved) = match state.api_provider {
      Deepseek =>
        (@settings.text(locale, DeepseekApiKey), state.deepseek_key_saved)
      Glm => (@settings.text(locale, GlmApiKey), state.glm_key_saved)
      OpenRouter =>
        (@settings.text(locale, OpenRouterApiKey), state.custom_key_saved)
      Custom => (@settings.text(locale, CustomApiKey), state.custom_key_saved)
    }
    rows.push(
      @settings.row(
        key_label,
        [
          @html.input(
            input_type=@html.InputType::Password,
            value=state.setup_api_key,
            placeholder=if key_saved {
              @settings.text(locale, SavedKey)
            } else {
              "sk-..."
            },
            on_input=dispatch.map(value => SetupApiKeyChanged(value)),
            attrs=@html.Attrs::build()
              .aria_label(@settings.text(locale, ApiKey))
              .data_set("focus-owner", "")
              .disabled(!settings_loaded),
          ),
          @html.button(
            // The id is layout only (grid placement); the fill is the
            // shared primary style.
            id="saveApiKey",
            class="button primary",
            disabled=!settings_loaded || state.setup_api_key.is_blank(),
            on_click=dispatch(SaveApiKey),
            @settings.text(locale, SaveApiKey),
          ),
        ],
        desc=@settings.text(locale, KeyStorageDescription),
        stack=true,
      ),
    )
  }
  rows
}

///|
/// The modal that owns the one truly blocking state a fresh install can be
/// in: SeekMoon is bring-your-own-key and no usable endpoint is configured.
/// It is the API settings section lifted out of the page — provider, URL,
/// and key are configured right here — so it opens over the chat, never
/// over the Settings form (which already shows the same section), and
/// disappears the moment a usable endpoint arrives. text(locale, NotNow) dismisses for
/// the session; the composer's BYOK notice keeps the reminder — and the way
/// back here — visible. Clicks inside must not bubble to the backdrop, whose
/// click dismisses.
pub fn api_setup_modal(
  dispatch : @cmd.Emit[Msg],
  state : State,
  locale : @i18n.Locale,
  is_desktop~ : Bool,
  menu~ : Menu,
) -> @html.Html {
  let title = match state.api_provider {
    Deepseek => text(locale, SetupDeepSeek)
    Glm => text(locale, SetupGlm)
    OpenRouter => text(locale, SetupOpenRouter)
    Custom => text(locale, SetupEndpoint)
  }
  @html.div(class="modal-backdrop", on_click=dispatch(DismissApiSetup), [
    @html.div(
      class="modal setup-modal",
      attrs=@html.Attrs::build().on_click(event => {
        event.stop_propagation()
        @cmd.none
      }),
      [
        @html.div(class="modal-title", title),
        @html.div(
          class="setup-modal-form",
          api_settings_rows(dispatch, state, locale, is_desktop~, menu~),
        ),
        @html.div(class="modal-actions", [
          @html.button(
            class="button secondary",
            on_click=dispatch(DismissApiSetup),
            text(locale, NotNow),
          ),
        ]),
      ],
    ),
  ])
}

///|
/// The root owns the shared select-menu identity. This is a view input only.
pub(all) struct Menu {
  open : Bool
  toggle : @cmd.Cmd
  dismiss : @cmd.Cmd
}

///|
fn Menu::control(
  self : Menu,
  id~ : String,
  options~ : Array[@select_control.ViewOption],
  selected~ : String,
  aria_label~ : String,
  change~ : @cmd.Emit[String],
  disabled~ : Bool,
) -> @html.Html {
  @select_control.Control::{
    id,
    groups: [{ label: aria_label, options, }],
    selected,
    disabled,
    open: self.open,
    toggle: self.toggle,
    dismiss: self.dismiss,
    change,
    title: aria_label,
    aria_label,
    presentation: Setting,
  }.render()
}
