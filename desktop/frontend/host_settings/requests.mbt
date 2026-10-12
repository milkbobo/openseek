///|
/// Seed (or refresh) the mirror from the host. A failed or malformed reply
/// leaves the current mirror in place — the broadcast channel will correct
/// it on the next change.
pub fn fetch_status(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let reply = @interop.bridge_request(
        channel,
        @commands.settings_get,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        _ => return
      }
      scheduler.add(dispatch(Loaded(reply)))
    })
    |> ignore
  })
}

///|
/// Push one settings patch to the host. The reply carries the post-write
/// state (`Applied` reconciles the mirror once no more writes
/// are in flight); a failure surfaces as a toast and leaves the host store
/// unchanged.
fn push_settings(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  patch : @protocol.SettingsSetPayload,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let reply = @interop.bridge_request(
        channel, @commands.settings_set, patch,
      ) catch {
        error => {
          scheduler.add(dispatch(SaveFailed(@interop.bridge_error_text(error))))
          return
        }
      }
      scheduler.add(dispatch(Applied(reply)))
    })
    |> ignore
  })
}

///|
fn provider_settings_patch(
  provider : ApiProvider,
  custom_api_url : String,
) -> @protocol.SettingsSetPayload {
  {
    provider: Some(
      if provider is OpenRouter {
        "custom"
      } else {
        provider.wire()
      },
    ),
    custom_api_url: match provider {
      OpenRouter => Some(OpenRouterChatCompletionsUrl)
      Custom if custom_api_url == OpenRouterChatCompletionsUrl => Some("")
      _ => None
    },
    deepseek_api_key: None,
    glm_api_key: None,
    custom_api_key: None,
    followup_behavior: None,
  }
}

///|
/// The URL is sent verbatim (not omitted when blank): a present-but-empty
/// field is the wire's "clear the stored value".
fn custom_url_settings_patch(url : String) -> @protocol.SettingsSetPayload {
  {
    provider: None,
    custom_api_url: Some(url),
    deepseek_api_key: None,
    glm_api_key: None,
    custom_api_key: None,
    followup_behavior: None,
  }
}

///|
fn api_key_settings_patch(
  provider : ApiProvider,
  key : String,
) -> @protocol.SettingsSetPayload {
  {
    provider: Some(
      if provider is OpenRouter {
        "custom"
      } else {
        provider.wire()
      },
    ),
    custom_api_url: if provider is OpenRouter {
      Some(OpenRouterChatCompletionsUrl)
    } else {
      None
    },
    deepseek_api_key: if provider is Deepseek {
      Some(key)
    } else {
      None
    },
    glm_api_key: if provider is Glm {
      Some(key)
    } else {
      None
    },
    custom_api_key: if provider is (OpenRouter | Custom) {
      Some(key)
    } else {
      None
    },
    followup_behavior: None,
  }
}

///|
fn followup_behavior_patch(
  behavior : FollowupBehavior,
) -> @protocol.SettingsSetPayload {
  {
    provider: None,
    custom_api_url: None,
    deepseek_api_key: None,
    glm_api_key: None,
    custom_api_key: None,
    followup_behavior: Some(behavior.wire()),
  }
}
