///|
priv enum Message {
  SetupDeepSeek
  SetupGlm
  SetupOpenRouter
  SetupEndpoint
  NotNow
  SaveSettings(String)
}

///|
fn text(locale : @i18n.Locale, message : Message) -> String {
  match (locale, message) {
    (English, SetupDeepSeek) => "Set up your DeepSeek API key"
    (Spanish, SetupDeepSeek) => "Configura tu clave de API de DeepSeek"
    (SimplifiedChinese, SetupDeepSeek) => "设置 DeepSeek API 密钥"
    (TraditionalChinese, SetupDeepSeek) => "設定 DeepSeek API 金鑰"
    (Japanese, SetupDeepSeek) => "DeepSeek API キーを設定"
    (English, SetupGlm) => "Set up your GLM API key"
    (Spanish, SetupGlm) => "Configura tu clave de API de GLM"
    (SimplifiedChinese, SetupGlm) => "设置 GLM API 密钥"
    (TraditionalChinese, SetupGlm) => "設定 GLM API 金鑰"
    (Japanese, SetupGlm) => "GLM API キーを設定"
    (English, SetupOpenRouter) => "Set up OpenRouter"
    (Spanish, SetupOpenRouter) => "Configura OpenRouter"
    (SimplifiedChinese, SetupOpenRouter) => "设置 OpenRouter"
    (TraditionalChinese, SetupOpenRouter) => "設定 OpenRouter"
    (Japanese, SetupOpenRouter) => "OpenRouter を設定"
    (English, SetupEndpoint) => "Set your endpoint URL"
    (Spanish, SetupEndpoint) => "Configura la URL de tu endpoint"
    (SimplifiedChinese, SetupEndpoint) => "设置端点 URL"
    (TraditionalChinese, SetupEndpoint) => "設定端點 URL"
    (Japanese, SetupEndpoint) => "エンドポイント URL を設定"
    (English, NotNow) => "Not now"
    (Spanish, NotNow) => "Ahora no"
    (SimplifiedChinese, NotNow) => "暂不设置"
    (TraditionalChinese, NotNow) => "暫不設定"
    (Japanese, NotNow) => "後で設定"
    (English, SaveSettings(p0)) => "Saving settings failed: \{p0}"
    (Spanish, SaveSettings(p0)) => "No se pudo guardar la configuración: \{p0}"
    (SimplifiedChinese, SaveSettings(p0)) => "保存设置失败：\{p0}"
    (TraditionalChinese, SaveSettings(p0)) => "儲存設定失敗：\{p0}"
    (Japanese, SaveSettings(p0)) =>
      "設定を保存できませんでした：\{p0}"
  }
}
