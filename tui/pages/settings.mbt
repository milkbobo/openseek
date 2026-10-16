///|
fn[Reply] codex_success(
  reply : @protocol.CodexCommandReply[Reply],
) -> Reply raise {
  match reply {
    CodexCommandSuccess(value) => value
    CodexCommandError(message) => fail(message)
  }
}

///|
async fn State::refresh_settings(self : State, client : @client.Client) -> Unit {
  match self.settings_section {
    0 =>
      if !self.settings_dirty {
        self.install_settings(
          client.call(@commands.settings_get, @protocol.NoPayload),
        )
      }
    1 => {
      let status = codex_success(
        client.call(@commands.codex_status, @protocol.NoPayload),
      )
      let account = codex_success(
        client.call(@commands.codex_account_read, { refresh_token: true, }),
      )
      self.settings_details = [
        "Codex app-server · " + status.status,
        ..@workbench.display(account.to_json()),
      ]
    }
    2 =>
      self.settings_details = @workbench.display(
        client.call(@commands.auth_status, @protocol.NoPayload).to_json(),
      )
    _ =>
      self.settings_details = @workbench.display(
        client.call(@commands.app_info, @protocol.NoPayload).to_json(),
      )
  }
}

///|
fn State::settings_lines(self : State, width : Int32) -> Array[String] {
  let lines : Array[String] = []
  for detail in self.settings_details {
    lines.append(
      @tui.Line::from_text(detail)
      .wrap(width.max(1))
      .map(line => line.to_text()),
    )
  }
  lines
}

///|
fn State::draw_settings(
  self : State,
  frame : @tui.Frame,
  area : @tui.Rect,
) -> Unit {
  self.label(frame, area, 0, "Settings", style=title_style())
  self.label(frame, area, 1, "Preferences for this device", style=muted_style())
  for index, name in ["Engine", "Codex", "Remote", "About"] {
    self.button(
      frame,
      @tui.Rect(
        row=area.row + 3,
        col=area.col + index * 14,
        width=(area.width - index * 14).max(0),
        height=1,
      ),
      name,
      SettingsSection(index),
      active=self.settings_section == index,
    )
  }
  let content = row(area, 5, height=(area.height - 5).max(0))
  match self.settings_section {
    0 => self.draw_engine(frame, content)
    1 => {
      self.label(frame, content, 0, "Codex account", style=title_style())
      self.label(
        frame,
        content,
        1,
        "Sign in with ChatGPT or manage this server's Codex configuration.",
        style=muted_style(),
      )
      for index, name in ["Sign in", "Cancel", "Sign out", "Open config"] {
        let action = [CodexLogin, CodexCancel, CodexLogout, CodexConfig][index]
        self.button(
          frame,
          @tui.Rect(
            row=content.row + 3,
            col=content.col + index * 17,
            width=(content.width - index * 17).max(0),
            height=1,
          ),
          name,
          action,
          active=self.focus == index,
        )
      }
      for index, line in self.settings_lines(content.width) {
        self.label(frame, content, index + 6, line)
      }
    }
    2 => {
      self.label(frame, content, 0, "Remote control", style=title_style())
      self.label(
        frame,
        content,
        1,
        "Register this server so your browser can connect to it.",
        style=muted_style(),
      )
      for index, name in ["Connect", "Disconnect", "Refresh"] {
        self.button(
          frame,
          @tui.Rect(
            row=content.row + 3,
            col=content.col + index * 18,
            width=(content.width - index * 18).max(0),
            height=1,
          ),
          name,
          [RemoteConnect, RemoteDisconnect, Refresh][index],
          active=self.focus == index,
        )
      }
      for index, line in self.settings_lines(content.width) {
        self.label(frame, content, index + 6, line)
      }
    }
    _ => {
      self.label(frame, content, 0, "SeekMoon", style=title_style())
      self.label(
        frame,
        content,
        1,
        "Terminal and desktop clients share the same backend services.",
        style=muted_style(),
      )
      for index, line in self.settings_lines(content.width) {
        self.label(frame, content, index + 3, line)
      }
      self.button(
        frame,
        row(content, 14),
        "Refresh",
        Refresh,
        active=self.focus == 0,
      )
    }
  }
  self.label(
    frame,
    area,
    area.height - 1,
    "Ctrl+←/→ categories · Tab focus · Enter activate · F5 refresh",
    style=muted_style(),
  )
}
