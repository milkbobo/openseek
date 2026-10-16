///|
pub(all) enum Page {
  Skills
  Settings
  Schedules
} derive(Eq)

///|
pub extend Page with Eq::{equal, not_equal}

///|
priv enum Action {
  Focus(Int32)
  SkillTab(Bool)
  SkillSelect(Int32)
  SkillPreview
  SkillInstall
  SkillRemove
  Refresh
  Provider(Int32)
  Followup
  SaveSettings
  SettingsSection(Int32)
  CodexLogin
  CodexCancel
  CodexLogout
  CodexConfig
  RemoteConnect
  RemoteDisconnect
  NewSchedule
  EditSchedule
  SelectSchedule(Int32)
  ScheduleAction(String)
  SaveSchedule(Bool)
  CancelForm
  Timing
  ShowRun(Int32)
  OpenRun(Int32)
  CloseLog
}

///|
priv struct Hit {
  area : @tui.Rect
  action : Action
}

///|
priv struct Form {
  id : String?
  name : @editor.Editor
  workspace : @editor.Editor
  task : @editor.Editor
  minutes : @editor.Editor
  timeout : @editor.Editor
  model : @editor.Editor
  mut once : Bool
  mut once_at : Int64?
}

///|
struct State {
  mut page : Page?
  mut focus : Int32
  mut focus_enabled : Bool
  mut notice : String
  hits : Array[Hit]
  mut bounds : @tui.Rect?
  mut page_offset : Int32
  mut reveal_focus : Bool
  scroll : @tui.Scroll
  query : @editor.Editor
  mut catalog_tab : Bool
  mut skill_index : Int32
  mut installed : Array[@protocol.InstalledSkill]
  mut catalog : Array[@protocol.MarketSkill]
  mut skill_content : String?
  mut settings : @protocol.SettingsStatusPayload?
  mut settings_dirty : Bool
  mut settings_section : Int32
  mut settings_details : Array[String]
  mut login_id : String?
  mut provider : Int32
  mut queue : Bool
  url : @editor.Editor
  key : @editor.Editor
  mut snapshot : @protocol.SchedulesReply
  mut schedule_index : Int32
  mut form : Form?
  mut log : String?
  mut pending_run : @protocol.ScheduleRun?
}

///|
pub fn State::State() -> State {
  {
    page: None,
    focus: 0,
    focus_enabled: true,
    notice: "",
    hits: [],
    bounds: None,
    page_offset: 0,
    reveal_focus: false,
    scroll: @tui.Scroll(),
    query: @editor.Editor(),
    catalog_tab: false,
    skill_index: 0,
    installed: [],
    catalog: [],
    skill_content: None,
    settings: None,
    settings_dirty: false,
    settings_section: 0,
    settings_details: [],
    login_id: None,
    provider: 0,
    queue: false,
    url: @editor.Editor(),
    key: @editor.Editor(),
    snapshot: { entries: [], runs: [], },
    schedule_index: 0,
    form: None,
    log: None,
    pending_run: None,
  }
}

///|
pub fn State::page(self : State) -> Page? {
  self.page
}

///|
pub fn State::close(self : State) -> Unit {
  self.page = None
  self.form = None
  self.hits.clear()
}

///|
pub async fn State::open(
  self : State,
  client : @client.Client,
  page : Page,
  context : @workbench.Context,
) -> Unit {
  self.page = Some(page)
  self.focus = 0
  self.page_offset = 0
  self.notice = ""
  self.form = None
  self.scroll.to_top()
  self.refresh(client, context)
}

///|
async fn State::refresh(
  self : State,
  client : @client.Client,
  context : @workbench.Context,
) -> Unit {
  match self.page {
    Some(Skills) => {
      let installed = client.call(
        @commands.skills_installed,
        @protocol.NoPayload,
      )
      let catalog = client.call(@commands.skills_catalog, @protocol.NoPayload)
      self.installed = match installed {
        InstalledSkills(skills) => skills
        InstalledSkillsError(message) => {
          self.notice = message
          []
        }
      }
      self.catalog = match catalog {
        SkillsCatalog(skills) => skills
        SkillsCatalogError(message) => {
          self.notice = message
          []
        }
      }
      self.skill_index = self.skill_index.min((self.skill_count() - 1).max(0))
    }
    Some(Settings) => self.refresh_settings(client)
    Some(Schedules) => {
      self.snapshot = client.call(@commands.schedules_list, @protocol.NoPayload)
      self.schedule_index = self.schedule_index.min(
        (self.snapshot.entries.length() - 1).max(0),
      )
    }
    None => ignore(context)
  }
}

///|
fn State::visible_installed(self : State) -> Array[@protocol.InstalledSkill] {
  let query = self.query.text().to_lower()
  self.installed.filter(skill => {
    query.is_empty() ||
    (skill.name + " " + skill.description).to_lower().contains(query)
  })
}

///|
fn State::visible_catalog(self : State) -> Array[@protocol.MarketSkill] {
  let query = self.query.text().to_lower()
  self.catalog.filter(skill => {
    query.is_empty() ||
    (skill.name + " " + skill.description).to_lower().contains(query)
  })
}

///|
fn State::skill_count(self : State) -> Int32 {
  if self.catalog_tab {
    self.visible_catalog().length()
  } else {
    self.visible_installed().length()
  }
}

///|
fn State::new_form(
  self : State,
  context : @workbench.Context,
  entry? : @protocol.ScheduleEntry,
) -> Unit {
  let spec = entry.map(entry => entry.spec)
  let once = spec is Some({ timing: Once(_), .. })
  let minutes = if spec is Some({ timing: Every(minutes), .. }) {
    minutes.to_string()
  } else if spec is Some({ timing: Once(at), .. }) {
    ((at - @env.now().reinterpret_as_int64() + 59999L) / 60000L)
    .max(1L)
    .to_string()
  } else {
    "30"
  }
  self.form = Some({
    id: entry.map(entry => entry.id),
    name: @editor.Editor(text=spec.map(spec => spec.name).unwrap_or("")),
    workspace: @editor.Editor(
      text=spec
        .bind(spec => spec.workspace)
        .unwrap_or(context.workspace.unwrap_or("")),
    ),
    task: @editor.Editor(text=spec.map(spec => spec.task).unwrap_or("")),
    minutes: @editor.Editor(text=minutes),
    timeout: @editor.Editor(
      text=spec.map(spec => spec.timeout_minutes.to_string()).unwrap_or("30"),
    ),
    model: @editor.Editor(
      text=spec.bind(spec => spec.model).unwrap_or(context.model),
    ),
    once,
    once_at: if spec is Some({ timing: Once(at), .. }) {
      Some(at)
    } else {
      None
    },
  })
  self.focus = 0
  self.page_offset = 0
  self.reveal_focus = true
  self.notice = ""
}

///|
fn Form::payload(
  self : Form,
  run_now : Bool,
  now : Int64,
) -> @protocol.ScheduleSavePayload raise {
  let value = self.minutes.text().trim()
  let timing : @protocol.ScheduleTiming = if self.once {
    let minutes = @string.parse_int(value)
    guard minutes >= 1 && minutes <= 525600 else {
      fail("Delay must be 1–525600 minutes")
    }
    Once(self.once_at.unwrap_or(now + minutes.to_int64() * 60000L))
  } else {
    let minutes = @string.parse_int(value)
    guard minutes >= 1 && minutes <= 525600 else {
      fail("Interval must be 1–525600 minutes")
    }
    Every(minutes)
  }
  let timeout_minutes = @string.parse_int(self.timeout.text().trim())
  guard timeout_minutes >= 1 && timeout_minutes <= 1440 else {
    fail("Timeout must be 1–1440 minutes")
  }
  let name = self.name.text().trim().to_owned()
  let task = self.task.text().trim().to_owned()
  guard !name.is_empty() && !task.is_empty() else {
    fail("Name and task are required")
  }
  let workspace = self.workspace.text().trim().to_owned()
  let model = self.model.text().trim().to_owned()
  {
    id: self.id,
    spec: {
      name,
      task,
      timing,
      timeout_minutes,
      workspace: if workspace.is_empty() {
        None
      } else {
        Some(workspace)
      },
      model: if model.is_empty() {
        None
      } else {
        Some(model)
      },
    },
    run_now,
  }
}

///|
fn State::install_settings(
  self : State,
  settings : @protocol.SettingsStatusPayload,
) -> Unit {
  self.settings = Some(settings)
  self.provider = match settings.provider {
    "glm" => 1
    "custom" if settings.custom_api_url ==
      Some("https://openrouter.ai/api/v1/chat/completions") => 2
    "custom" => 3
    _ => 0
  }
  self.queue = settings.followup_behavior == "queue"
  self.url.set_text(settings.custom_api_url.unwrap_or(""))
  self.settings_dirty = false
}

///|
pub async fn State::notification(
  self : State,
  client : @client.Client,
  notification : @protocol.Notification,
  context : @workbench.Context,
) -> Unit {
  match notification {
    SettingsChanged(settings) if !self.settings_dirty =>
      self.install_settings(settings)
    SkillsChanged if self.page is Some(Skills) => self.refresh(client, context)
    SessionChanged(_) if self.page is Some(Schedules) =>
      self.refresh(client, context)
    AuthChanged(status) if self.page is Some(Settings) &&
      self.settings_section == 2 =>
      self.settings_details = @workbench.display(status.to_json())
    CodexStatusChanged(_) if self.page is Some(Settings) &&
      self.settings_section == 1 => self.refresh_settings(client)
    _ => ()
  }
}

///|
pub fn State::paste(self : State, value : StringView) -> Bool {
  guard self.page is Some(page) else { return false }
  match page {
    Skills if self.focus == 0 => {
      self.query.insert(value)
      self.skill_index = 0
    }
    Settings if self.settings_section == 0 && self.focus == 1 => {
      self.url.insert(value)
      self.settings_dirty = true
    }
    Settings if self.settings_section == 0 && self.focus == 2 => {
      self.key.insert(value)
      self.settings_dirty = true
    }
    Schedules =>
      if self.form is Some(form) {
        match self.focus {
          0 => form.name.insert(value)
          1 => form.workspace.insert(value)
          2 => form.task.insert(value)
          4 => {
            form.minutes.insert(value)
            form.once_at = None
          }
          5 => form.timeout.insert(value)
          6 => form.model.insert(value)
          _ => ()
        }
      }
    _ => ()
  }
  true
}

///|
pub fn State::take_open_run(self : State) -> @protocol.ScheduleRun? {
  let run = self.pending_run
  self.pending_run = None
  run
}
