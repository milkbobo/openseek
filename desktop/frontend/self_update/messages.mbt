// Feature-owned UI messages; every locale is exhaustive.

///|
priv enum Message {
  UpdateLabel
  RestartingLabel
  RestartToUpdateLabel
  InterruptForUpdate
  KeepWorking
  RestartNow
  UpdateServer(String)
  UpdateReply(String)
  RestartQuestion(String)
}

///|
fn text(locale : @i18n.Locale, message : Message) -> String {
  match (locale, message) {
    (English, UpdateLabel) => "Update"
    (Spanish, UpdateLabel) => "Actualizar"
    (SimplifiedChinese, UpdateLabel) => "更新"
    (TraditionalChinese, UpdateLabel) => "更新"
    (Japanese, UpdateLabel) => "更新"
    (English, RestartingLabel) => "Restarting…"
    (Spanish, RestartingLabel) => "Reiniciando…"
    (SimplifiedChinese, RestartingLabel) => "正在重启…"
    (TraditionalChinese, RestartingLabel) => "正在重啟…"
    (Japanese, RestartingLabel) => "再起動中…"
    (English, RestartToUpdateLabel) => "Restart to update"
    (Spanish, RestartToUpdateLabel) => "Reiniciar para actualizar"
    (SimplifiedChinese, RestartToUpdateLabel) => "重启以更新"
    (TraditionalChinese, RestartToUpdateLabel) => "重啟以更新"
    (Japanese, RestartToUpdateLabel) => "再起動して更新"
    (English, InterruptForUpdate) =>
      "A conversation is still running. Restarting the app interrupts it; the transcript so far is saved."
    (Spanish, InterruptForUpdate) =>
      "Hay una conversación en curso. Reiniciar la aplicación la interrumpirá; la transcripción hasta este momento está guardada."
    (SimplifiedChinese, InterruptForUpdate) =>
      "仍有对话正在运行。重启应用会中断运行，已有的对话记录将会保留。"
    (TraditionalChinese, InterruptForUpdate) =>
      "仍有對話正在執行。重啟應用會中斷執行，已有的對話記錄將會保留。"
    (Japanese, InterruptForUpdate) =>
      "実行中のチャットがあります。アプリを再起動すると実行が中断されますが、既存のチャット履歴は保持されます。"
    (English, KeepWorking) => "Keep working"
    (Spanish, KeepWorking) => "Seguir trabajando"
    (SimplifiedChinese, KeepWorking) => "继续工作"
    (TraditionalChinese, KeepWorking) => "繼續工作"
    (Japanese, KeepWorking) => "作業を続行"
    (English, RestartNow) => "Restart now"
    (Spanish, RestartNow) => "Reiniciar ahora"
    (SimplifiedChinese, RestartNow) => "立即重启"
    (TraditionalChinese, RestartNow) => "立即重啟"
    (Japanese, RestartNow) => "今すぐ再起動"
    (English, UpdateServer(p0)) => "Could not reach the update server: \{p0}"
    (Spanish, UpdateServer(p0)) =>
      "No se pudo conectar con el servidor de actualizaciones: \{p0}"
    (SimplifiedChinese, UpdateServer(p0)) =>
      "无法连接更新服务器：\{p0}"
    (TraditionalChinese, UpdateServer(p0)) =>
      "無法連線更新伺服器：\{p0}"
    (Japanese, UpdateServer(p0)) =>
      "更新サーバーに接続できません：\{p0}"
    (English, UpdateReply(p0)) => "The update server answered unusably: \{p0}"
    (Spanish, UpdateReply(p0)) =>
      "El servidor de actualizaciones devolvió una respuesta no válida: \{p0}"
    (SimplifiedChinese, UpdateReply(p0)) =>
      "更新服务器返回了无效响应：\{p0}"
    (TraditionalChinese, UpdateReply(p0)) =>
      "更新伺服器返回了無效響應：\{p0}"
    (Japanese, UpdateReply(p0)) =>
      "更新サーバーが無効な応答を返しました：\{p0}"
    (English, RestartQuestion(p0)) => "Restart into \{p0}?"
    (Spanish, RestartQuestion(p0)) => "¿Reiniciar en \{p0}?"
    (SimplifiedChinese, RestartQuestion(p0)) => "重启至 \{p0}？"
    (TraditionalChinese, RestartQuestion(p0)) => "重啟至 \{p0}？"
    (Japanese, RestartQuestion(p0)) =>
      "再起動して \{p0} に更新しますか？"
  }
}
