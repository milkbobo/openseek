///|
struct ChatKey {
  session : String
  workspace : String?
  archived : Bool
} derive(Eq, Hash)

///|
enum RowKind {
  User
  Assistant
  Reasoning
  Tool
  Notice
  Error
} derive(Eq)

///|
struct Row {
  kind : RowKind
  label : String
  text : String
  sequence : Int32?
} derive(Eq)

///|
struct Chat {
  mut key : ChatKey
  mut title : String
  mut session_root : String?
  rows : Array[Row]
  mut layout : ChatLayout?
  draft : @editor.Editor
  attachments : @attachments.Draft
  scroll : @tui.Scroll
  selection : @tui.Selection
  mut watermark : Int32
  mut loaded : Bool
  mut loading : Bool
  mut needs_reload : Bool
  buffered : Array[@protocol.SessionCommitPayload]
  mut run_id : String?
  mut lifecycle_generation : Int32
  mut snapshot_generation : Int32
  mut live_answer : String
  mut live_reasoning : String
  mut status : String
  mut goal : String?
  mut prediction : @agent_protocol.PredictionRecord?
  pending : Map[String, String]
  queued : Map[String, String]
  steering_drafts : Map[String, SteeringDraft]
  queued_drafts : Map[String, SteeringDraft]
}

///|
fn Chat::Chat(key : ChatKey, title~ : String = "New chat") -> Chat {
  {
    key,
    title,
    session_root: None,
    rows: [],
    layout: None,
    draft: @editor.Editor(),
    attachments: @attachments.Draft(),
    scroll: @tui.Scroll(stick_to_bottom=true),
    selection: @tui.Selection(),
    watermark: 0,
    loaded: false,
    loading: false,
    needs_reload: false,
    buffered: [],
    run_id: None,
    lifecycle_generation: 0,
    snapshot_generation: 0,
    live_answer: "",
    live_reasoning: "",
    status: "Ready",
    goal: None,
    prediction: None,
    pending: {},
    queued: {},
    steering_drafts: {},
    queued_drafts: {},
  }
}

///|
enum Focus {
  Composer
  Sidebar
  Terminal
  Workspace
  Pages
} derive(Eq)

///|
struct TerminalTab {
  id : String
  screen : @terminal.Screen
  session : String
  mut cols : Int32
  mut rows : Int32
  mut exit_code : Int32?
}

///|
struct State {
  workspace : @workspace.State
  pages : @pages.State
  mut right_visible : Bool
  mut editor_visible : Bool
  codex : @codexchat.State
  mut codex_model : String?
  mut resync_needed : Bool
  chats : Map[ChatKey, Chat]
  mut active : Chat
  mut sidebar : Array[ChatKey]
  mut sidebar_index : Int32
  mut sidebar_cursor : Int32
  mut sidebar_mode : SidebarMode
  collapsed_projects : Set[String]
  mut projects : Array[String]
  mut project_entry : @editor.Editor?
  mut sidebar_visible : Bool
  mut focus : Focus
  mut model : String
  mut model_explicit : Bool
  mut thinking : @protocol.OpenSeekThinking
  mut max_steps : Int32?
  mut queue_followup : Bool
  mut settings : @protocol.SettingsStatusPayload?
  mut approvals : Array[@protocol.PendingApprovalPayload]
  mut approval_generation : Int32
  terminals : Array[TerminalTab]
  mut terminal_opening : Int32
  terminal_pending : Map[String, Array[@protocol.TerminalOutputPayload]]
  terminal_pending_exits : Map[String, Int32]
  mut terminal_index : Int32
  mut terminal_visible : Bool
  mut terminal_height : Int32
  mut panel_title : String?
  mut panel_lines : Array[String]
  panel_scroll : @tui.Scroll
  panel_selection : @tui.Selection
  mut notice : String
  mut busy : Bool
  mut counter : Int32
  mut server_url : String
  mut size : @tui.Size
}

///|
fn State::State(workspace : String?) -> State {
  let active = Chat({ session: fresh_id(), workspace, archived: false, })
  {
    workspace: @workspace.State(),
    pages: @pages.State(),
    right_visible: true,
    editor_visible: true,
    codex: @codexchat.State(),
    codex_model: None,
    resync_needed: false,
    chats: Map([(active.key, active)]),
    active,
    sidebar: [active.key],
    sidebar_index: 0,
    sidebar_cursor: 0,
    sidebar_mode: ChatsMode,
    collapsed_projects: Set([]),
    projects: [],
    project_entry: None,
    sidebar_visible: true,
    focus: Composer,
    model: "deepseek-v4-pro",
    model_explicit: false,
    thinking: @protocol.ThinkingHigh,
    max_steps: None,
    queue_followup: false,
    settings: None,
    approvals: [],
    approval_generation: 0,
    terminals: [],
    terminal_opening: 0,
    terminal_pending: {},
    terminal_pending_exits: {},
    terminal_index: 0,
    terminal_visible: false,
    terminal_height: 12,
    panel_title: None,
    panel_lines: [],
    panel_scroll: @tui.Scroll(),
    panel_selection: @tui.Selection(),
    notice: "Connecting…",
    busy: false,
    counter: 0,
    server_url: "",
    size: @tui.Size(width=100, height=32),
  }
}

///|
fn fresh_id() -> String {
  "tui-\{@env.now()}"
}

///|
fn State::submission(self : State) -> String {
  self.counter += 1
  "\{fresh_id()}-\{self.counter}"
}

///|
fn State::new_chat(self : State, workspace : String?) -> Unit {
  self.workspace.clear()
  let chat = Chat({ session: self.submission(), workspace, archived: false, })
  self.chats[chat.key] = chat
  self.sidebar.insert(0, chat.key)
  self.active = chat
  self.reveal_sidebar_chat(chat.key)
  self.pages.close()
  self.sidebar_index = 0
  self.focus = Composer
  self.panel_title = None
  self.terminal_visible = false
}

///|
fn State::panel(self : State, title : String, lines : Array[String]) -> Unit {
  self.panel_title = Some(title)
  self.pages.close()
  self.panel_lines = lines
  self.panel_scroll.to_top()
  self.panel_selection.clear()
  self.terminal_visible = false
  self.focus = Composer
}

///|
fn Chat::notice(self : Chat, text : String, error~ : Bool = false) -> Unit {
  self.rows.push({
    kind: if error {
      Error
    } else {
      Notice
    },
    label: if error {
      "Error"
    } else {
      "Notice"
    },
    text,
    sequence: None,
  })
}

///|
fn State::chat_for_run(self : State, run_id : String?) -> Chat? {
  guard run_id is Some(id) else { return None }
  self.chats.values().find_first(chat => chat.run_id == Some(id))
}

///|
fn State::unique_session(self : State, session : String) -> Chat? {
  let matches = self.chats
    .values()
    .filter(chat => chat.key.session == session)
    .collect()
  if matches is [chat] {
    Some(chat)
  } else {
    None
  }
}

///|
fn Chat::prediction_text(self : Chat) -> String? {
  guard self.run_id is None &&
    self.draft.is_empty() &&
    self.prediction is Some(record) &&
    record.source_sequence <= self.watermark &&
    record.outcome is @agent_protocol.Completed(text=Some(text), ..) else {
    return None
  }
  Some(text)
}
