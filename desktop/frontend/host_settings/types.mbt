///|
const OpenRouterChatCompletionsUrl : String = "https://openrouter.ai/api/v1/chat/completions"

///|
/// Which chat-completions endpoint the engine talks to. SeekMoon runs are
/// bring-your-own-key only: the hosted proxy is retired. `Deepseek` is the
/// official endpoint and needs the user's own key; `OpenRouter` is a preset
/// over the existing custom endpoint; `Custom` accepts any other
/// OpenAI-compatible endpoint, whose key is optional. The retired hosted
/// names (`openseek` / `openseek-staging`) parse as `Deepseek` so old
/// stores and old clients land on the BYOK default instead of wedging.
/// The setting (and its credentials) live on the host; this mirror is what
/// `settings.get`/`set` replies and the `settings.changed` broadcast last
/// reported.
pub(all) enum ApiProvider {
  Deepseek
  Glm
  OpenRouter
  Custom
} derive(Eq)

///|
pub(all) enum FollowupBehavior {
  FollowupSteer
  FollowupQueue
} derive(Eq)

///|
fn FollowupBehavior::parse(value : String) -> FollowupBehavior {
  if value == "queue" {
    FollowupQueue
  } else {
    FollowupSteer
  }
}

///|
pub fn FollowupBehavior::wire(self : FollowupBehavior) -> String {
  match self {
    FollowupSteer => "steer"
    FollowupQueue => "queue"
  }
}

///|
pub fn ApiProvider::wire(self : ApiProvider) -> String {
  match self {
    Deepseek => "deepseek"
    Glm => "glm"
    OpenRouter => "openrouter"
    Custom => "custom"
  }
}

///|
/// Unknown stored values fall back to the default provider, so a downgrade
/// (or a corrupted store) degrades to the BYOK default instead of wedging
/// the app.
fn ApiProvider::parse(value : String) -> ApiProvider {
  match value.trim() {
    "openseek" | "openseek-staging" | "deepseek" => Deepseek
    "glm" => Glm
    "openrouter" => OpenRouter
    "custom" => Custom
    _ => Deepseek
  }
}

///|
pub extend ApiProvider with Eq::{equal, not_equal}

///|
pub extend FollowupBehavior with Eq::{equal, not_equal}
