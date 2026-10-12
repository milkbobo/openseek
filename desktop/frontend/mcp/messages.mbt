// Feature-owned UI messages; all built-in languages are exhaustive.

///|
priv enum UiMessage {
  Servers
  Description
  CheckAgain
  Checking
  Connecting
  NotConfigured(String)
  NoServers(String)
  ConfigRejected(String)
  CheckFailed
  Connected
  ToolCount(Int)
  NoTools
  NoToolsReason
  Failed
  Skipped
  SkippedReason
}

///|
fn text(locale : @i18n.Locale, message : UiMessage) -> String {
  match (locale, message) {
    (English, Servers) => "MCP servers"
    (Spanish, Servers) => "Servidores MCP"
    (SimplifiedChinese, Servers) => "MCP 服务器"
    (TraditionalChinese, Servers) => "MCP 伺服器"
    (Japanese, Servers) => "MCP サーバー"
    (English, Description) =>
      "Servers listed in mcp.json give the agent extra tools. Edits apply from the next message of each conversation."
    (Spanish, Description) =>
      "Los servidores indicados en mcp.json dan al agente herramientas adicionales. Los cambios se aplican a partir del siguiente mensaje de cada conversación."
    (SimplifiedChinese, Description) =>
      "mcp.json 中配置的服务器会为智能体提供额外的工具。修改从每个对话的下一条消息起生效。"
    (TraditionalChinese, Description) =>
      "mcp.json 中設定的伺服器會為代理提供額外的工具。修改從每個對話的下一則訊息起生效。"
    (Japanese, Description) =>
      "mcp.json に記載したサーバーがエージェントに追加のツールを提供します。変更は各会話の次のメッセージから適用されます。"
    (English, CheckAgain) => "Check again"
    (Spanish, CheckAgain) => "Comprobar de nuevo"
    (SimplifiedChinese, CheckAgain) => "重新检查"
    (TraditionalChinese, CheckAgain) => "重新檢查"
    (Japanese, CheckAgain) => "再確認"
    (English, Checking) => "Checking…"
    (Spanish, Checking) => "Comprobando…"
    (SimplifiedChinese, Checking) => "正在检查…"
    (TraditionalChinese, Checking) => "正在檢查…"
    (Japanese, Checking) => "確認中…"
    (English, Connecting) => "Connecting to the configured servers…"
    (Spanish, Connecting) => "Conectando con los servidores configurados…"
    (SimplifiedChinese, Connecting) => "正在连接已配置的服务器…"
    (TraditionalChinese, Connecting) =>
      "正在連線至已設定的伺服器…"
    (Japanese, Connecting) =>
      "設定済みのサーバーに接続しています…"
    (English, NotConfigured(path)) =>
      "Nothing is configured yet. Create \{path} to add servers."
    (Spanish, NotConfigured(path)) =>
      "Aún no hay nada configurado. Crea \{path} para añadir servidores."
    (SimplifiedChinese, NotConfigured(path)) =>
      "尚未配置。创建 \{path} 即可添加服务器。"
    (TraditionalChinese, NotConfigured(path)) =>
      "尚未設定。建立 \{path} 即可新增伺服器。"
    (Japanese, NotConfigured(path)) =>
      "まだ設定されていません。\{path} を作成するとサーバーを追加できます。"
    (English, NoServers(path)) => "\{path} lists no servers."
    (Spanish, NoServers(path)) => "\{path} no contiene ningún servidor."
    (SimplifiedChinese, NoServers(path)) =>
      "\{path} 中没有配置任何服务器。"
    (TraditionalChinese, NoServers(path)) =>
      "\{path} 中沒有設定任何伺服器。"
    (Japanese, NoServers(path)) =>
      "\{path} にサーバーがありません。"
    (English, ConfigRejected(path)) => "\{path} could not be loaded"
    (Spanish, ConfigRejected(path)) => "No se pudo cargar \{path}"
    (SimplifiedChinese, ConfigRejected(path)) => "无法加载 \{path}"
    (TraditionalChinese, ConfigRejected(path)) => "無法載入 \{path}"
    (Japanese, ConfigRejected(path)) =>
      "\{path} を読み込めませんでした"
    (English, CheckFailed) => "The check could not run"
    (Spanish, CheckFailed) => "No se pudo ejecutar la comprobación"
    (SimplifiedChinese, CheckFailed) => "检查未能执行"
    (TraditionalChinese, CheckFailed) => "檢查未能執行"
    (Japanese, CheckFailed) => "確認を実行できませんでした"
    (English, Connected) => "Connected"
    (Spanish, Connected) => "Conectado"
    (SimplifiedChinese, Connected) => "已连接"
    (TraditionalChinese, Connected) => "已連線"
    (Japanese, Connected) => "接続済み"
    (English, ToolCount(1)) => "1 tool"
    (English, ToolCount(count)) => "\{count} tools"
    (Spanish, ToolCount(1)) => "1 herramienta"
    (Spanish, ToolCount(count)) => "\{count} herramientas"
    (SimplifiedChinese, ToolCount(count)) => "\{count} 个工具"
    (TraditionalChinese, ToolCount(count)) => "\{count} 個工具"
    (Japanese, ToolCount(count)) => "\{count} 個のツール"
    (English, NoTools) => "No tools"
    (Spanish, NoTools) => "Sin herramientas"
    (SimplifiedChinese, NoTools) => "没有工具"
    (TraditionalChinese, NoTools) => "沒有工具"
    (Japanese, NoTools) => "ツールなし"
    (English, NoToolsReason) => "The server connected and offers no tools."
    (Spanish, NoToolsReason) =>
      "El servidor se conectó y no ofrece herramientas."
    (SimplifiedChinese, NoToolsReason) =>
      "服务器已连接，但没有提供任何工具。"
    (TraditionalChinese, NoToolsReason) =>
      "伺服器已連線，但沒有提供任何工具。"
    (Japanese, NoToolsReason) =>
      "サーバーに接続しましたが、ツールは提供されていません。"
    (English, Failed) => "Failed"
    (Spanish, Failed) => "Error"
    (SimplifiedChinese, Failed) => "失败"
    (TraditionalChinese, Failed) => "失敗"
    (Japanese, Failed) => "失敗"
    (English, Skipped) => "Skipped"
    (Spanish, Skipped) => "Omitido"
    (SimplifiedChinese, Skipped) => "已跳过"
    (TraditionalChinese, Skipped) => "已略過"
    (Japanese, Skipped) => "スキップ"
    (English, SkippedReason) =>
      "Not started: the servers before it already reached the tool limit."
    (Spanish, SkippedReason) =>
      "No se inició: los servidores anteriores ya alcanzaron el límite de herramientas."
    (SimplifiedChinese, SkippedReason) =>
      "未启动：排在前面的服务器已经用完了工具数量上限。"
    (TraditionalChinese, SkippedReason) =>
      "未啟動：排在前面的伺服器已經用完了工具數量上限。"
    (Japanese, SkippedReason) =>
      "起動していません。先のサーバーでツール数の上限に達しました。"
  }
}
