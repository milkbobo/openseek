///|
async fn State::action(
  self : State,
  client : @client.Client,
  action : Action,
  context : @workbench.Context,
) -> Unit {
  self.notice = ""
  match action {
    Focus(index) => {
      self.focus = index
      self.reveal_focus = true
    }
    Refresh => self.refresh(client, context)
    SkillTab(catalog) => {
      self.catalog_tab = catalog
      self.skill_index = 0
      self.skill_content = None
    }
    SkillSelect(index) => {
      self.skill_index = index
      self.focus = 2
      self.preview_skill(client)
    }
    SkillPreview => self.preview_skill(client)
    SkillInstall => {
      guard self.visible_catalog().get(self.skill_index) is Some(skill) else {
        return
      }
      let reply = client.call(@commands.skills_install, {
        module_name: skill.module_name,
        version: skill.version,
        package_path: Some(skill.package_path),
      })
      self.notice = match reply {
        SkillInstalled(skill) => "Installed " + skill.name
        SkillInstallError(message) => message
      }
      self.refresh(client, context)
    }
    SkillRemove => {
      guard self.visible_installed().get(self.skill_index) is Some(skill) else {
        return
      }
      guard skill.registry is Some(_) else {
        self.notice = "Hand-written skills are managed in your skills directory."
        return
      }
      self.notice = match
        client.call(@commands.skills_uninstall, { id: skill.id, }) {
        SkillUninstalled => "Removed " + skill.name
        SkillUninstallError(message) => message
      }
      self.refresh(client, context)
      self.skill_content = None
    }
    Provider(delta) => {
      self.provider = (self.provider + delta + 4) % 4
      if self.provider == 2 {
        self.url.set_text("https://openrouter.ai/api/v1/chat/completions")
      }
      self.settings_dirty = true
    }
    Followup => {
      self.queue = !self.queue
      self.settings_dirty = true
    }
    SettingsSection(index) => {
      self.settings_section = index
      self.focus = 0
      self.page_offset = 0
      self.refresh_settings(client)
    }
    CodexLogin => {
      let reply = codex_success(
        client.call(@commands.codex_account_login_start, {
          kind_: "chatgpt",
          use_hosted_login_success_page: true,
          app_brand: "SeekMoon",
        }),
      )
      self.login_id = Some(reply.login_id)
      self.settings_details = [
        "Finish signing in using your browser:",
        reply.auth_url,
      ]
    }
    CodexCancel =>
      if self.login_id is Some(login_id) {
        ignore(
          codex_success(
            client.call(@commands.codex_account_login_cancel, { login_id, }),
          ),
        )
        self.login_id = None
        self.refresh_settings(client)
      }
    CodexLogout => {
      ignore(
        codex_success(
          client.call(@commands.codex_account_logout, @protocol.NoPayload),
        ),
      )
      self.refresh_settings(client)
    }
    CodexConfig => {
      ignore(
        codex_success(
          client.call(@commands.codex_config_open, @protocol.NoPayload),
        ),
      )
      self.notice = "Opened Codex configuration on the server"
    }
    RemoteConnect =>
      self.settings_details = @workbench.display(
        client.call(@commands.auth_connect, @protocol.NoPayload).to_json(),
      )
    RemoteDisconnect =>
      self.settings_details = @workbench.display(
        client.call(@commands.auth_disconnect, @protocol.NoPayload).to_json(),
      )
    SaveSettings => {
      let provider = match self.provider {
        0 => "deepseek"
        1 => "glm"
        _ => "custom"
      }
      let key = self.key.text()
      let reply = client.call(@commands.settings_set, {
        provider: Some(provider),
        custom_api_url: if self.provider == 2 {
          Some("https://openrouter.ai/api/v1/chat/completions")
        } else if self.provider == 3 {
          Some(self.url.text())
        } else {
          None
        },
        deepseek_api_key: if self.provider == 0 && !key.is_empty() {
          Some(key)
        } else {
          None
        },
        glm_api_key: if self.provider == 1 && !key.is_empty() {
          Some(key)
        } else {
          None
        },
        custom_api_key: if self.provider >= 2 && !key.is_empty() {
          Some(key)
        } else {
          None
        },
        followup_behavior: Some(if self.queue { "queue" } else { "steer" }),
      })
      self.install_settings(reply)
      self.key.clear()
      self.notice = "Settings saved"
    }
    NewSchedule => self.new_form(context)
    EditSchedule =>
      if self.snapshot.entries.get(self.schedule_index) is Some(entry) {
        self.new_form(context, entry~)
      }
    SelectSchedule(index) => self.schedule_index = index
    ScheduleAction(action) =>
      if self.snapshot.entries.get(self.schedule_index) is Some(entry) {
        self.snapshot = client.call(@commands.schedules_action, {
          id: entry.id,
          action,
        })
        self.schedule_index = self.schedule_index.min(
          (self.snapshot.entries.length() - 1).max(0),
        )
      }
    SaveSchedule(run_now) => {
      guard self.form is Some(form) else { return }
      self.snapshot = client.call(
        @commands.schedules_save,
        form.payload(run_now, @env.now().reinterpret_as_int64()),
      )
      self.form = None
      self.focus = 0
      self.notice = if run_now {
        "Saved; run requested"
      } else {
        "Schedule saved"
      }
    }
    CancelForm => self.form = None
    CloseLog => self.log = None
    ShowRun(index) =>
      if self.snapshot.runs.get(index) is Some(run) {
        match
          client.call(@commands.fs_read_file, {
            path: run.log_path,
            root: None,
          }) {
          Content(content~, ..) => {
            self.log = Some(content)
            self.scroll.to_top()
          }
          _ => self.notice = "This run log cannot be displayed as text."
        }
      }
    OpenRun(index) => self.pending_run = self.snapshot.runs.get(index)
    Timing =>
      if self.form is Some(form) {
        form.once = !form.once
        form.once_at = None
      }
  }
}

///|
async fn State::preview_skill(self : State, client : @client.Client) -> Unit {
  let reply = if self.catalog_tab {
    guard self.visible_catalog().get(self.skill_index) is Some(skill) else {
      return
    }
    client.call(@commands.skills_content, {
      module_name: skill.module_name,
      version: skill.version,
      package_path: Some(skill.package_path),
    })
  } else {
    guard self.visible_installed().get(self.skill_index) is Some(skill) else {
      return
    }
    client.call(@commands.skills_installed_content, { id: skill.id, })
  }
  match reply {
    SkillContent(content) => {
      self.skill_content = Some(content)
      self.scroll.to_top()
    }
    SkillContentError(message) => self.notice = message
  }
}

///|
async fn State::safe_action(
  self : State,
  client : @client.Client,
  action : Action,
  context : @workbench.Context,
) -> Unit {
  self.action(client, action, context) catch {
    error if @async.is_being_cancelled() => raise error
    error => self.notice = error.to_string()
  }
}

///|
pub async fn State::key(
  self : State,
  client : @client.Client,
  key : @input.KeyEvent,
  context : @workbench.Context,
) -> Bool {
  guard self.page is Some(page) else { return false }
  if key.kind is Release {
    return true
  }
  if key.code is Escape {
    if self.form is Some(_) {
      self.form = None
    } else if self.log is Some(_) {
      self.log = None
    } else if self.skill_content is Some(_) && page is Skills {
      self.skill_content = None
    } else {
      self.close()
    }
    return true
  }
  if page is Settings && key.modifiers.ctrl() && key.code is (Left | Right) {
    self.safe_action(
      client,
      SettingsSection(
        (self.settings_section + (if key.code is Left { 3 } else { 1 })) % 4,
      ),
      context,
    )
    return true
  }
  if key.code is F5 {
    self.safe_action(client, Refresh, context)
    return true
  }
  if key.code is (PageUp | PageDown) {
    if page is Settings || self.form is Some(_) {
      self.page_offset = (self.page_offset +
      (if key.code is PageUp { -8 } else { 8 })).max(0)
    } else if key.code is PageUp {
      self.scroll.page_up()
    } else {
      self.scroll.page_down()
    }
    return true
  }
  if key.code is Tab {
    let count = match page {
      Skills => 5
      Settings =>
        if self.settings_section == 0 {
          6
        } else if self.settings_section == 1 {
          4
        } else if self.settings_section == 2 {
          3
        } else {
          1
        }
      Schedules => if self.form is Some(_) { 10 } else { 1 }
    }
    self.focus = (
        self.focus + (if key.modifiers.shift() { count - 1 } else { 1 })
      ) %
      count
    self.reveal_focus = true
    return true
  }
  match page {
    Skills =>
      if self.focus == 0 && !(key.code is Enter) {
        ignore(self.query.key(key))
        self.skill_index = 0
      } else {
        match key.code {
          Left | Right if self.focus == 1 =>
            self.safe_action(client, SkillTab(!self.catalog_tab), context)
          Up => self.skill_index = (self.skill_index - 1).max(0)
          Down =>
            self.skill_index = (self.skill_index + 1).min(
              (self.skill_count() - 1).max(0),
            )
          Enter if self.focus == 3 =>
            self.safe_action(
              client,
              if self.catalog_tab {
                SkillInstall
              } else {
                SkillRemove
              },
              context,
            )
          Enter if self.focus == 4 => self.safe_action(client, Refresh, context)
          Enter => self.safe_action(client, SkillPreview, context)
          Char('i') if self.catalog_tab =>
            self.safe_action(client, SkillInstall, context)
          Char('d') if !self.catalog_tab =>
            self.safe_action(client, SkillRemove, context)
          _ => ()
        }
      }
    Settings =>
      if self.settings_section == 0 {
        match self.focus {
          0 =>
            match key.code {
              Left => self.safe_action(client, Provider(-1), context)
              Right | Enter => self.safe_action(client, Provider(1), context)
              _ => ()
            }
          1 => {
            let before = self.url.text()
            ignore(self.url.key(key))
            if before != self.url.text() {
              self.settings_dirty = true
            }
          }
          2 => {
            let before = self.key.text()
            ignore(self.key.key(key))
            if before != self.key.text() {
              self.settings_dirty = true
            }
          }
          3 if key.code is (Left | Right | Enter | Char(' ')) =>
            self.safe_action(client, Followup, context)
          4 if key.code is Enter =>
            self.safe_action(client, SaveSettings, context)
          5 if key.code is Enter => self.safe_action(client, Refresh, context)
          _ => ()
        }
      } else if key.code is Enter {
        let action = if self.settings_section == 1 {
          [CodexLogin, CodexCancel, CodexLogout, CodexConfig]
          .get(self.focus)
          .unwrap_or(Refresh)
        } else if self.settings_section == 2 {
          [RemoteConnect, RemoteDisconnect, Refresh]
          .get(self.focus)
          .unwrap_or(Refresh)
        } else {
          Refresh
        }
        self.safe_action(client, action, context)
      }
    Schedules =>
      if self.form is Some(form) {
        if key.modifiers.ctrl() && key.code is Char('s') {
          self.safe_action(client, SaveSchedule(false), context)
        } else {
          match self.focus {
            0 => ignore(form.name.key(key))
            1 => ignore(form.workspace.key(key))
            2 => ignore(form.task.key(key))
            3 if key.code is (Left | Right | Enter | Char(' ')) =>
              self.safe_action(client, Timing, context)
            4 => {
              let before = form.minutes.text()
              ignore(form.minutes.key(key))
              if form.minutes.text() != before {
                form.once_at = None
              }
            }
            5 => ignore(form.timeout.key(key))
            6 => ignore(form.model.key(key))
            7 if key.code is Enter =>
              self.safe_action(client, SaveSchedule(false), context)
            8 if key.code is Enter =>
              self.safe_action(client, SaveSchedule(true), context)
            9 if key.code is Enter =>
              self.safe_action(client, CancelForm, context)
            _ => ()
          }
        }
      } else {
        match key.code {
          Up => self.schedule_index = (self.schedule_index - 1).max(0)
          Down =>
            self.schedule_index = (self.schedule_index + 1).min(
              (self.snapshot.entries.length() - 1).max(0),
            )
          Char('n') => self.safe_action(client, NewSchedule, context)
          Enter | Char('e') => self.safe_action(client, EditSchedule, context)
          Char('r') => self.safe_action(client, ScheduleAction("run"), context)
          Char('p') =>
            if self.snapshot.entries.get(self.schedule_index) is Some(entry) {
              self.safe_action(
                client,
                ScheduleAction(if entry.enabled { "pause" } else { "resume" }),
                context,
              )
            }
          Char('s') => self.safe_action(client, ScheduleAction("stop"), context)
          Char('d') =>
            self.safe_action(client, ScheduleAction("delete"), context)
          _ => ()
        }
      }
  }
  true
}

///|
pub async fn State::mouse(
  self : State,
  client : @client.Client,
  event : @input.MouseEvent,
  context : @workbench.Context,
) -> Bool {
  guard self.page is Some(_) else { return false }
  let row = event.row - 1
  let col = event.col - 1
  if event.kind is Press(Left) {
    if self.hits
      .rev_iter()
      .find_first(hit => {
        row >= hit.area.row &&
        row < hit.area.row + hit.area.height &&
        col >= hit.area.col &&
        col < hit.area.col + hit.area.width
      })
      is Some(hit) {
      self.safe_action(client, hit.action, context)
    }
  } else if event.kind is Scroll(direction) {
    let delta = match direction {
      Up => -3
      Down => 3
      Left | Right => return true
    }
    if self.page is Some(Settings) || self.form is Some(_) {
      self.page_offset = (self.page_offset + delta).max(0)
    } else {
      self.scroll.scroll_by(delta)
    }
  }
  true
}
