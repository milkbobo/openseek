///|
fn title_style() -> @tui.Style {
  @tui.Style(fg=Rgb(230, 236, 246), bold=true)
}

///|
fn muted_style() -> @tui.Style {
  @tui.Style(fg=Rgb(145, 157, 177))
}

///|
fn active_style() -> @tui.Style {
  @tui.Style(fg=Rgb(142, 202, 255), bg=Rgb(34, 47, 68), bold=true)
}

///|
fn row(area : @tui.Rect, offset : Int32, height~ : Int32 = 1) -> @tui.Rect {
  @tui.Rect(
    row=area.row + offset,
    col=area.col,
    width=area.width,
    height=height.min((area.height - offset).max(0)),
  )
}

///|
fn State::label(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  offset : Int32,
  text : String,
  style~ : @tui.Style = @tui.Style(),
) -> Unit {
  if offset >= 0 && offset < area.height {
    let target = row(area, offset)
    if self.bounds is Some(bounds) &&
      (target.row < bounds.row || target.row >= bounds.row + bounds.height) {
      return
    }
    frame.line(target, @tui.Line::from_text(text, style~))
  }
}

///|
fn State::button(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  text : String,
  action : Action,
  active~ : Bool = false,
) -> Unit {
  if area.height <= 0 || area.width <= 0 {
    return
  }
  if self.bounds is Some(bounds) &&
    (area.row < bounds.row || area.row >= bounds.row + bounds.height) {
    return
  }
  let area = @tui.Rect(
    row=area.row,
    col=area.col,
    width=(text.length() + 4).min(area.width),
    height=1,
  )
  frame.fill(
    area,
    style=if active {
      active_style()
    } else {
      @tui.Style(bg=Rgb(36, 40, 50), fg=Rgb(204, 215, 234))
    },
  )
  frame.line(
    area,
    @tui.Line::from_text(
      "[ " + text + " ]",
      style=if active { active_style() } else { @tui.Style() },
    ),
  )
  self.hits.push({ area, action, })
}

///|
fn State::field(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  offset : Int32,
  title : String,
  editor : @editor.Editor,
  index : Int32,
  height~ : Int32 = 1,
  secret~ : Bool = false,
) -> Unit {
  self.label(
    frame,
    area,
    offset,
    title,
    style=if self.focus == index { active_style() } else { muted_style() },
  )
  let field = row(area, offset + 1, height~)
  let field = if self.bounds is Some(bounds) {
    let start = field.row.max(bounds.row)
    @tui.Rect(
      row=start,
      col=field.col,
      width=field.width,
      height=((field.row + field.height).min(bounds.row + bounds.height) - start).max(
        0,
      ),
    )
  } else {
    field
  }
  if field.height <= 0 {
    return
  }
  frame.fill(field, style=@tui.Style(bg=Rgb(28, 33, 43)))
  if secret {
    frame.line(
      field,
      @tui.Line::from_text(
        if editor.is_empty() {
          "Enter a new API key"
        } else {
          "•".repeat(editor.text().length().min(40))
        },
        style=muted_style(),
      ),
    )
    if self.focus_enabled && self.focus == index {
      frame.set_cursor(
        field,
        col=editor.text().length().min((field.width - 1).max(0)),
      )
    }
  } else {
    editor.draw(
      frame,
      field,
      focused=self.focus_enabled && self.focus == index,
      style=@tui.Style(bg=Rgb(28, 33, 43)),
    )
  }
  self.hits.push({ area: field, action: Focus(index), })
}

///|
pub fn State::draw(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  focused~ : Bool = true,
) -> Unit {
  self.hits.clear()
  self.focus_enabled = focused
  self.bounds = Some(area)
  guard self.page is Some(page) else { return }
  let width = (area.width - 4).min(108).max(1)
  let visible_height = (area.height - 2).max(1)
  let full_height = if page is Settings {
    (self.settings_lines(width).length() + 13).max(25)
  } else if self.form is Some(_) {
    25
  } else {
    visible_height
  }
  if self.reveal_focus {
    let target = if page is Settings && self.settings_section == 0 {
      [7, 10, 13, 17, 19, 19].get(self.focus).unwrap_or(0)
    } else if page is Settings {
      if self.settings_section == 3 {
        19
      } else {
        8
      }
    } else if self.form is Some(_) {
      [6, 8, 11, 14, 14, 14, 17, 19, 19, 19].get(self.focus).unwrap_or(0)
    } else {
      0
    }
    if target < self.page_offset {
      self.page_offset = target
    }
    if target >= self.page_offset + visible_height {
      self.page_offset = target - visible_height + 2
    }
    self.reveal_focus = false
  }
  self.page_offset = self.page_offset.min((full_height - visible_height).max(0))
  let content = @tui.Rect(
    row=area.row + 1 - self.page_offset,
    col=area.col + ((area.width - width) / 2).max(0),
    width~,
    height=full_height.max(visible_height),
  )
  match page {
    Skills => self.draw_skills(frame, content)
    Settings => self.draw_settings(frame, content)
    Schedules => self.draw_schedules(frame, content)
  }
  if !self.notice.is_empty() {
    self.label(
      frame,
      area,
      area.height - 1,
      self.notice,
      style=@tui.Style(fg=Rgb(244, 194, 126)),
    )
  }
}

///|
fn State::draw_skills(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
) -> Unit {
  self.label(frame, area, 0, "Skills", style=title_style())
  self.label(
    frame,
    area,
    1,
    "Reusable instructions for your agents",
    style=muted_style(),
  )
  self.button(
    frame,
    row(area, 3),
    "Installed",
    SkillTab(false),
    active=!self.catalog_tab,
  )
  self.button(
    frame,
    @tui.Rect(
      row=area.row + 3,
      col=area.col + 17,
      width=(area.width - 17).max(0),
      height=1,
    ),
    "Catalog",
    SkillTab(true),
    active=self.catalog_tab,
  )
  self.button(
    frame,
    @tui.Rect(
      row=area.row + 3,
      col=area.col + 32,
      width=(area.width - 32).max(0),
      height=1,
    ),
    "Refresh",
    Refresh,
    active=self.focus == 4,
  )
  self.field(frame, area, 5, "Search skills", self.query, 0)
  let body = row(area, 8, height=(area.height - 9).max(0))
  if self.skill_content is Some(content) && body.width < 65 {
    self.label(
      frame,
      body,
      0,
      "SKILL.md · Esc returns to skills",
      style=title_style(),
    )
    self.button(
      frame,
      row(body, 2),
      if self.catalog_tab {
        "Install skill"
      } else {
        "Remove skill"
      },
      if self.catalog_tab {
        SkillInstall
      } else {
        SkillRemove
      },
      active=self.focus == 3,
    )
    frame.lines(
      row(body, 4, height=(body.height - 4).max(0)),
      content.split("\n").map(value => @tui.Line::from_text(value)).collect(),
      scroll=self.scroll,
    )
    return
  }
  let list_width = if self.skill_content is Some(_) && body.width >= 65 {
    body.width * 2 / 5
  } else {
    body.width
  }
  let list = @tui.Rect(
    row=body.row,
    col=body.col,
    width=list_width,
    height=body.height,
  )
  let rows = if self.catalog_tab {
    self
    .visible_catalog()
    .map(skill => {
      (skill.name, skill.module_name + " @" + skill.version, skill.description)
    })
  } else {
    self
    .visible_installed()
    .map(skill => {
      (
        skill.name,
        if skill.source.is_empty() {
          "Hand-written"
        } else {
          skill.source
        },
        skill.description,
      )
    })
  }
  if rows.is_empty() {
    self.label(
      frame,
      list,
      1,
      if self.catalog_tab {
        "No matching catalog skills"
      } else {
        "No matching installed skills"
      },
      style=muted_style(),
    )
  }
  let count = (list.height / 4).max(1)
  let top = (self.skill_index - count + 1).max(0)
  for offset in 0..<count {
    let index = top + offset
    guard rows.get(index) is Some((name, source, description)) else { break }
    let card = row(list, offset * 4, height=3)
    let selected = index == self.skill_index
    if selected {
      frame.fill(card, style=@tui.Style(bg=Rgb(31, 40, 56)))
    }
    self.label(
      frame,
      card,
      0,
      (if selected { "› " } else { "  " }) + name,
      style=if selected { active_style() } else { title_style() },
    )
    self.label(frame, card, 1, "  " + source, style=muted_style())
    self.label(frame, card, 2, "  " + description, style=muted_style())
    self.hits.push({ area: card, action: SkillSelect(index), })
  }
  if self.skill_content is Some(content) && body.width >= 65 {
    let detail = @tui.Rect(
      row=body.row,
      col=body.col + list_width + 2,
      width=(body.width - list_width - 2).max(0),
      height=body.height,
    )
    self.label(frame, detail, 0, "SKILL.md", style=title_style())
    self.button(
      frame,
      row(detail, 2),
      if self.catalog_tab {
        "Install skill"
      } else {
        "Remove skill"
      },
      if self.catalog_tab {
        SkillInstall
      } else {
        SkillRemove
      },
      active=self.focus == 3,
    )
    let lines = content
      .split("\n")
      .map(value => @tui.Line::from_text(value))
      .collect()
    frame.lines(
      row(detail, 4, height=(detail.height - 4).max(0)),
      lines,
      scroll=self.scroll,
    )
  }
  self.label(
    frame,
    area,
    area.height - 1,
    "Tab focus · ↑↓ select · Enter details · i install · d remove · F5 refresh",
    style=muted_style(),
  )
}

///|
fn State::draw_engine(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
) -> Unit {
  let area = @tui.Rect(
    row=area.row,
    col=area.col,
    width=area.width.min(78),
    height=area.height,
  )
  self.label(frame, area, 0, "API PROVIDER", style=muted_style())
  let providers = ["DeepSeek", "GLM", "OpenRouter", "Custom"]
  self.label(frame, area, 1, "Provider", style=muted_style())
  self.button(
    frame,
    row(area, 2),
    "‹ " + providers[self.provider] + " ›",
    Provider(1),
    active=self.focus == 0,
  )
  self.field(frame, area, 4, "Chat completions endpoint URL", self.url, 1)
  self.field(frame, area, 7, "API key", self.key, 2, secret=true)
  let saved = self.settings
    .map(settings => {
      match self.provider {
        0 => settings.has_deepseek_key
        1 => settings.has_glm_key
        _ => settings.has_custom_key
      }
    })
    .unwrap_or(false)
  self.label(
    frame,
    area,
    9,
    if saved {
      "A key is saved on the server. Leave blank to keep it."
    } else {
      "Enter your provider API key to start."
    },
    style=muted_style(),
  )
  self.label(frame, area, 11, "FOLLOW-UP MESSAGES", style=muted_style())
  self.button(
    frame,
    row(area, 12),
    if self.queue {
      "Queue after the current turn"
    } else {
      "Steer the active turn"
    },
    Followup,
    active=self.focus == 3,
  )
  self.button(
    frame,
    row(area, 14),
    "Save settings",
    SaveSettings,
    active=self.focus == 4,
  )
  self.button(
    frame,
    @tui.Rect(
      row=area.row + 14,
      col=area.col + 21,
      width=(area.width - 21).max(0),
      height=1,
    ),
    "Refresh",
    Refresh,
    active=self.focus == 5,
  )
  self.label(
    frame,
    area,
    18,
    "Tab focus · ←→ change choice · Enter activate · F5 refresh",
    style=muted_style(),
  )
}

///|
fn timing_text(timing : @protocol.ScheduleTiming) -> String {
  match timing {
    Every(minutes) => "Every \{minutes} min"
    Once(at) => "Once · \{at} ms since epoch"
  }
}

///|
fn State::draw_schedules(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
) -> Unit {
  self.label(frame, area, 0, "Scheduled tasks", style=title_style())
  self.label(
    frame,
    area,
    1,
    "Run agent tasks in the background, once or on a repeating interval",
    style=muted_style(),
  )
  if self.form is Some(form) {
    self.draw_form(frame, row(area, 3, height=(area.height - 3).max(0)), form)
    return
  }
  self.button(frame, row(area, 3), "+ New task", NewSchedule)
  self.button(
    frame,
    @tui.Rect(
      row=area.row + 3,
      col=area.col + 19,
      width=(area.width - 19).max(0),
      height=1,
    ),
    "Refresh",
    Refresh,
  )
  if self.log is Some(content) {
    self.button(frame, row(area, 5), "Back to tasks", CloseLog)
    frame.lines(
      row(area, 7, height=(area.height - 8).max(0)),
      content.split("\n").map(value => @tui.Line::from_text(value)).collect(),
      scroll=self.scroll,
    )
    return
  }
  let run_height = if self.snapshot.runs.is_empty() {
    0
  } else {
    (area.height / 3).min(6).max(0)
  }
  let list = row(area, 6, height=(area.height - 8 - run_height).max(0))
  if self.snapshot.entries.is_empty() {
    self.label(
      frame,
      list,
      1,
      "No scheduled tasks yet. Create one to get started.",
      style=muted_style(),
    )
  }
  let count = (list.height / 6).max(1)
  let top = (self.schedule_index - count + 1).max(0)
  for offset in 0..<count {
    let index = top + offset
    guard self.snapshot.entries.get(index) is Some(entry) else { break }
    let card = row(list, offset * 6, height=5)
    let selected = index == self.schedule_index
    if selected {
      frame.fill(card, style=@tui.Style(bg=Rgb(31, 40, 56)))
    }
    self.label(
      frame,
      card,
      0,
      (if selected { "› " } else { "  " }) +
      entry.spec.name +
      (if entry.enabled { "  ● Enabled" } else { "  ○ Paused" }),
      style=title_style(),
    )
    self.label(
      frame,
      card,
      1,
      "  " +
      timing_text(entry.spec.timing) +
      " · " +
      entry.spec.workspace.unwrap_or("Automatic workspace"),
      style=muted_style(),
    )
    self.label(frame, card, 2, "  " + entry.spec.task, style=muted_style())
    self.hits.push({ area: card, action: SelectSchedule(index), })
    if selected {
      self.button(frame, row(card, 4), "Run", ScheduleAction("run"))
      self.button(
        frame,
        @tui.Rect(
          row=card.row + 4,
          col=card.col + 10,
          width=(card.width - 10).max(0),
          height=1,
        ),
        if entry.enabled {
          "Pause"
        } else {
          "Resume"
        },
        ScheduleAction(if entry.enabled { "pause" } else { "resume" }),
      )
      self.button(
        frame,
        @tui.Rect(
          row=card.row + 4,
          col=card.col + 23,
          width=(card.width - 23).max(0),
          height=1,
        ),
        "Edit",
        EditSchedule,
      )
      self.button(
        frame,
        @tui.Rect(
          row=card.row + 4,
          col=card.col + 34,
          width=(card.width - 34).max(0),
          height=1,
        ),
        "Stop",
        ScheduleAction("stop"),
      )
      self.button(
        frame,
        @tui.Rect(
          row=card.row + 4,
          col=card.col + 45,
          width=(card.width - 45).max(0),
          height=1,
        ),
        "Delete",
        ScheduleAction("delete"),
      )
    }
  }
  if run_height > 0 {
    let recent = row(area, area.height - run_height - 1, height=run_height)
    self.label(frame, recent, 0, "Recent runs", style=title_style())
    for index in 0..<((run_height - 1) / 2).max(0) {
      guard self.snapshot.runs.get(index) is Some(run) else { break }
      let status = match run.status {
        Running => "Running"
        Succeeded => "Completed"
        Failed(_) => "Failed"
        Stopped => "Stopped"
        TimedOut => "Timed out"
        Interrupted => "Interrupted"
      }
      self.label(
        frame,
        recent,
        1 + index * 2,
        run.name + " · " + status,
        style=muted_style(),
      )
      self.button(
        frame,
        row(recent, 2 + index * 2),
        "Open chat",
        OpenRun(index),
      )
      self.button(
        frame,
        @tui.Rect(
          row=recent.row + 2 + index * 2,
          col=recent.col + 17,
          width=(recent.width - 17).max(0),
          height=1,
        ),
        "Run log",
        ShowRun(index),
      )
    }
  }
  self.label(
    frame,
    area,
    area.height - 1,
    "↑↓ select · n new · Enter edit · r run · p pause/resume · s stop · d delete",
    style=muted_style(),
  )
}

///|
fn State::draw_form(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
  form : Form,
) -> Unit {
  self.label(
    frame,
    area,
    0,
    if form.id is Some(_) {
      "Edit scheduled task"
    } else {
      "New scheduled task"
    },
    style=title_style(),
  )
  self.field(frame, area, 2, "Name", form.name, 0)
  self.field(
    frame,
    area,
    4,
    "Working directory (blank creates one automatically)",
    form.workspace,
    1,
  )
  self.field(frame, area, 6, "Task", form.task, 2, height=3)
  self.button(
    frame,
    row(area, 11),
    if form.once {
      "Once in"
    } else {
      "Every"
    },
    Timing,
    active=self.focus == 3,
  )
  let left = @tui.Rect(
    row=area.row,
    col=area.col + 17,
    width=((area.width - 17) / 2).max(0),
    height=area.height,
  )
  let right = @tui.Rect(
    row=area.row,
    col=area.col + 18 + left.width,
    width=(area.width - left.width - 18).max(0),
    height=area.height,
  )
  self.field(frame, left, 10, "Minutes", form.minutes, 4)
  self.field(frame, right, 10, "Timeout (minutes)", form.timeout, 5)
  self.field(
    frame,
    area,
    13,
    "Model (blank uses server default)",
    form.model,
    6,
  )
  self.button(
    frame,
    row(area, 16),
    "Save schedule",
    SaveSchedule(false),
    active=self.focus == 7,
  )
  self.button(
    frame,
    @tui.Rect(
      row=area.row + 16,
      col=area.col + 21,
      width=(area.width - 21).max(0),
      height=1,
    ),
    "Save and run",
    SaveSchedule(true),
    active=self.focus == 8,
  )
  self.button(
    frame,
    @tui.Rect(
      row=area.row + 16,
      col=area.col + 41,
      width=(area.width - 41).max(0),
      height=1,
    ),
    "Cancel",
    CancelForm,
    active=self.focus == 9,
  )
  self.label(
    frame,
    area,
    18,
    "Tab moves between fields · Ctrl+S saves · Esc cancels",
    style=muted_style(),
  )
}
