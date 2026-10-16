///|
fn muted() -> @tui.Style {
  @tui.Style(fg=Rgb(133, 148, 169))
}

///|
fn accent() -> @tui.Style {
  @tui.Style(fg=Rgb(118, 194, 255), bold=true)
}

///|
fn row_style(kind : RowKind) -> @tui.Style {
  match kind {
    User => @tui.Style(fg=Rgb(126, 221, 185), bold=true)
    Assistant => accent()
    Reasoning => muted()
    Tool => @tui.Style(fg=Rgb(219, 192, 132))
    Notice => muted()
    Error => @tui.Style(fg=Rgb(255, 136, 145))
  }
}

///|
fn markdown_lines(
  text : String,
  width : Int32,
  dim~ : Bool = false,
) -> Array[@tui.Line] {
  @markdown.render(text, width, dim~)
}

///|
// Keep source values as well as wrapped lines: reconnects and Codex updates
// can replace rows without changing their count or sequence numbers.
priv struct ChatLayout {
  width : Int32
  rows : Array[Row]
  row_lines : Array[Array[@tui.Line]]
  goal : String?
  live_reasoning : String
  live_answer : String
  pending : Map[String, String]
  queued : Map[String, String]
  lines : Array[@tui.Line]
}

///|
fn Chat::lines(self : Chat, width : Int32) -> Array[@tui.Line] {
  let cached = self.layout.filter(layout => layout.width == width)
  if cached is Some(layout) &&
    layout.rows == self.rows &&
    layout.goal == self.goal &&
    layout.live_reasoning == self.live_reasoning &&
    layout.live_answer == self.live_answer &&
    layout.pending == self.pending &&
    layout.queued == self.queued {
    return layout.lines
  }
  let lines : Array[@tui.Line] = []
  let row_lines : Array[Array[@tui.Line]] = []
  if self.goal is Some(goal) {
    lines.append(markdown_lines("Goal · \{goal}", width))
    lines.push(@tui.Line::from_text(""))
  }
  if self.rows.is_empty() {
    lines.push(
      @tui.Line::from_text("What would you like to build?", style=accent()),
    )
    lines.push(@tui.Line::from_text(""))
    for
      text in [
        "Send a prompt to start a durable conversation.", "Type /help for chats, projects, skills, schedules, Git, and settings.",
        "Ctrl+T opens a real terminal in this chat's workspace.", "Ctrl+P opens commands; Ctrl+N starts another chat.",
      ] {
      lines.append(markdown_lines(text, width, dim=true))
    }
  }
  for index, row in self.rows {
    let wrapped = if cached is Some(layout) &&
      layout.rows.get(index) == Some(row) {
      layout.row_lines[index]
    } else {
      let sequence = row.sequence.map(n => " · #\{n}").unwrap_or("")
      [
        @tui.Line::from_text(
          "\{row.label}\{sequence}",
          style=row_style(row.kind),
        ),
        ..if row.kind is Tool || row.kind is Error {
          row.text
          .split("\n")
          .flat_map(raw => @tui.Line::from_text(raw).wrap(width.max(1)).iter())
          .collect()
        } else {
          markdown_lines(row.text, width, dim=row.kind is Reasoning)
        },
        @tui.Line::from_text(""),
      ]
    }
    row_lines.push(wrapped)
    lines.append(wrapped)
  }
  if !self.live_reasoning.is_empty() {
    lines.push(@tui.Line::from_text("Thinking…", style=muted()))
    lines.append(markdown_lines(self.live_reasoning, width, dim=true))
    lines.push(@tui.Line::from_text(""))
  }
  if !self.live_answer.is_empty() {
    lines.push(@tui.Line::from_text("SeekMoon · streaming", style=accent()))
    lines.append(markdown_lines(self.live_answer, width))
  }
  for _, text in self.pending {
    lines.append(markdown_lines("↗ Awaiting steer: \{text}", width, dim=true))
  }
  for id, text in self.queued {
    lines.append(markdown_lines("◷ Queued \{id}: \{text}", width, dim=true))
  }
  self.layout = Some({
    width,
    rows: self.rows.copy(),
    row_lines,
    goal: self.goal,
    live_reasoning: self.live_reasoning,
    live_answer: self.live_answer,
    pending: self.pending.copy(),
    queued: self.queued.copy(),
    lines,
  })
  lines
}

///|
fn State::view(self : State, size : @tui.Size) -> @tui.Frame {
  let frame = @tui.Frame(
    width=size.width,
    height=size.height,
    inherit_colors=true,
  )
  frame.fill(
    frame.area(),
    style=@tui.Style(bg=Rgb(17, 22, 30), fg=Rgb(221, 227, 235)),
  )
  if size.width < 25 || size.height < 7 {
    frame.line(
      frame.area(),
      @tui.Line::from_text("SeekMoon · resize terminal", style=accent()),
    )
    return frame
  }
  let regions = self.regions(size)
  frame.fill(regions.header, style=@tui.Style(bg=Rgb(28, 36, 49)))
  frame.line(
    regions.header,
    @tui.Line([
      @tui.Span(" SeekMoon ", style=accent()),
      @tui.Span(" / ", style=muted()),
      @tui.Span(self.active.key.workspace.unwrap_or("Personal workspace")),
    ]),
  )
  self.draw_sidebar(frame, regions)
  let provider = if self.active.codex_id() is Some(_) {
    "Codex"
  } else {
    self.settings.map(settings => settings.provider).unwrap_or("OpenSeek")
  }
  let model = if self.active.codex_id() is Some(_) {
    self.codex_model.unwrap_or("default")
  } else {
    self.model
  }
  frame.line(
    regions.tabs,
    @tui.Line::from_text(
      " Chat · \{provider} / \{model}  ·  \{if self.active.codex_id() is Some(_) { self.codex_effort.unwrap_or("default") } else { self.thinking.wire() }}",
      style=muted(),
    ),
  )
  if self.pages.page() is Some(_) {
    let page_area = @tui.Rect(
      row=regions.main.row + 1,
      col=regions.main.col,
      width=regions.main.width,
      height=(regions.main.height - 1).max(0),
    )
    self.pages.draw(frame, page_area, focused=self.focus is Pages)
  } else {
    if self.panel_title is Some(title) {
      let lines = [
        @tui.Line::from_text(title, style=accent()),
        @tui.Line::from_text("Esc returns to chat", style=muted()),
        @tui.Line::from_text(""),
        ..self.panel_lines
        .iter()
        .flat_map(text => markdown_lines(text, regions.chat.width).iter()),
      ]
      frame.lines(
        regions.chat,
        lines,
        scroll=self.panel_scroll,
        selection=self.panel_selection,
      )
    } else {
      frame.lines(
        regions.chat,
        self.active.lines(regions.chat.width),
        scroll=self.active.scroll,
        selection=self.active.selection,
      )
    }
    self.draw_composer(frame, regions.composer)
    self.workspace.draw_editor(
      frame,
      regions.editor,
      focused=self.focus is Workspace,
    )
    self.workspace.draw_tree(
      frame,
      regions.tree,
      focused=self.focus is Workspace,
    )
  }
  if self.terminal_visible {
    frame.fill(regions.terminal_header, style=@tui.Style(bg=Rgb(31, 40, 54)))
    let terminal_tabs : Array[@tui.Span] = []
    for index, tab in self.terminals {
      let label = tab.screen.title().unwrap_or("Terminal · " + tab.session)
      let status = tab.exit_code.map(code => " (\{code})").unwrap_or("")
      terminal_tabs.push(
        @tui.Span(
          " \{index + 1}: \{label}\{status} ",
          style=if index == self.terminal_index { accent() } else { muted() },
        ),
      )
    }
    frame.line(regions.terminal_header, @tui.Line(terminal_tabs))
    if self.terminals.get(self.terminal_index) is Some(tab) {
      tab.screen.draw(frame, regions.terminal, focused=self.focus is Terminal)
    }
  }
  let footer = if self.focus is Terminal {
    " Ctrl+T hide terminal · Ctrl+←/→ tabs · Alt+W close · F6 focus chat"
  } else if self.focus is Workspace {
    " Ctrl+S save · Ctrl+W close tab · F6 next pane · Ctrl+T terminal"
  } else if self.pages.page() is Some(_) {
    " Tab next control · Enter activate · Esc chat · Ctrl+T terminal"
  } else if !self.codex.requests().is_empty() {
    " Codex needs an answer · /codex requests"
  } else if self.approvals.iter().any(approval => !approval.answered) {
    " Approval required · /approvals"
  } else if self.loading_connection {
    if self.startup_submission is Some(_) {
      " Loading… · input queued · Ctrl+C cancel · Ctrl+Q quit"
    } else {
      " Loading conversations… · you can type · Ctrl+Q quit"
    }
  } else if self.busy {
    " Working… · Ctrl+Q quit"
  } else {
    " F6 pane · Ctrl+P commands · Ctrl+T terminal · Ctrl+Q quit"
  }
  frame.line(regions.footer, @tui.Line::from_text(footer, style=muted()))
  frame
}

///|
fn State::draw_composer(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
) -> Unit {
  if area.width == 0 || area.height == 0 {
    return
  }
  let chat = self.active
  let mode = if chat.key.archived {
    "Archived · /unarchive to continue"
  } else if chat.run_id is Some(_) {
    if self.queue_followup {
      "Queue next · /stop interrupts"
    } else {
      "Steer now · /stop interrupts"
    }
  } else {
    chat.status
  }
  let attachment_count = chat.attachments.labels().length()
  let mode = if attachment_count == 0 {
    mode
  } else {
    "\{mode} · \{attachment_count} attachments (/detach all)"
  }
  frame.line(
    area,
    @tui.Line::from_text(" ─ \{mode} · \{self.notice}", style=muted()),
  )
  let input_area = @tui.Rect(
    row=area.row + 1,
    col=area.col + 2,
    width=(area.width - 3).max(1),
    height=(area.height - 1).max(1),
  )
  frame.text(row=area.row + 1, col=area.col, "> ", style=accent())
  if chat.draft.is_empty() && chat.prediction_text() is Some(prediction) {
    frame.line(
      input_area,
      @tui.Line::from_text("\{prediction}  ⇥", style=muted()),
    )
    if self.focus is Composer {
      frame.set_cursor(input_area)
    }
  } else {
    chat.draft.draw(frame, input_area, focused=self.focus is Composer)
  }
}
