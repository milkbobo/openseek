///|
fn State::terminal_area(self : State) -> (Int32, Int32) {
  let area = self.regions(self.size, terminal=true).terminal
  (area.width.max(1), area.height.max(1))
}

///|
async fn State::open_terminal(
  self : State,
  client : @client.Client,
  command : String?,
) -> Unit {
  if command is None && !self.terminals.is_empty() {
    self.terminal_visible = true
    self.focus = Terminal
    self.resize_terminals(client)
    self.terminal_focus(client, true)
    return
  }
  let session = self.active.codex_id().unwrap_or(self.active.key.session)
  let workspace = self.active.key.workspace
  let (cols, rows) = self.terminal_area()
  let screen = @terminal.Screen(cols~, rows~)
  let mut attached = false
  self.terminal_opening += 1
  defer {
    self.terminal_opening -= 1
    if self.terminal_opening == 0 {
      self.terminal_pending.clear()
      self.terminal_pending_exits.clear()
    }
    if !attached {
      screen.close()
    }
  }
  let reply = client.call(@commands.terminal_open, @protocol.TerminalOpenPayload::{
    session,
    workspace,
    cols,
    rows,
    command,
  })
  let tab : TerminalTab = {
    id: reply.id,
    screen,
    session,
    cols,
    rows,
    exit_code: self.terminal_pending_exits.get(reply.id),
  }
  self.terminal_pending_exits.remove(reply.id)
  let mut last_sequence = None
  if self.terminal_pending.get(reply.id) is Some(pending) {
    // Feed every buffered chunk before suspending, so newly arriving output
    // cannot overtake any part of the pre-reply output.
    for payload in pending {
      screen.feed(@base64.decode(payload.data))
      last_sequence = Some(payload.sequence)
    }
    self.terminal_pending.remove(reply.id)
  }
  self.terminals.push(tab)
  attached = true
  self.terminal_focus(client, false) catch {
    error if @async.is_being_cancelled() => raise error
    error => self.notice = "Previous terminal focus: \{error.to_string()}"
  }
  self.terminal_index = self.terminals.length() - 1
  self.terminal_visible = true
  self.focus = Terminal
  self.panel_title = None
  if last_sequence is Some(sequence) {
    ignore(
      client.call(@commands.terminal_ack, @protocol.TerminalAckPayload::{
        id: reply.id,
        sequence,
      }),
    )
  }
  terminal_write(client, tab, screen.take_reply())
  self.resize_terminals(client)
  self.terminal_focus(client, true)
}

///|
async fn State::close_terminal(self : State, client : @client.Client) -> Unit {
  guard self.terminals.get(self.terminal_index) is Some(tab) else { return }
  ignore(
    client.call(@commands.terminal_close, @protocol.TerminalClosePayload::{
      id: tab.id,
    }),
  )
  tab.screen.close()
  if self.terminals.search_by(candidate => candidate.id == tab.id)
    is Some(index) {
    ignore(self.terminals.remove(index))
    if self.terminal_index > index {
      self.terminal_index -= 1
    } else if self.terminal_index == index {
      self.terminal_index = (index - 1).max(0)
    }
  }
  if self.terminals.is_empty() {
    self.terminal_visible = false
    self.focus = if self.pages.page() is Some(_) { Pages } else { Composer }
  } else {
    self.terminal_focus(client, true)
  }
}

///|
async fn terminal_write(
  client : @client.Client,
  tab : TerminalTab,
  bytes : Bytes,
) -> Unit {
  if bytes.is_empty() || tab.exit_code is Some(_) {
    return
  }
  ignore(
    client.call(@commands.terminal_input, @protocol.TerminalInputPayload::{
      id: tab.id,
      data: None,
      data_base64: Some(@base64.encode(bytes)),
    }),
  )
}

///|
async fn State::terminal_output(
  self : State,
  client : @client.Client,
  payload : @protocol.TerminalOutputPayload,
) -> Unit {
  if self.terminals.iter().find_first(tab => tab.id == payload.id) is Some(tab) {
    tab.screen.feed(@base64.decode(payload.data))
    ignore(
      client.call(@commands.terminal_ack, @protocol.TerminalAckPayload::{
        id: payload.id,
        sequence: payload.sequence,
      }),
    )
    terminal_write(client, tab, tab.screen.take_reply())
  } else if self.terminal_opening > 0 {
    // Do not ACK until attached. The server's per-PTY output window keeps
    // early output bounded while the terminal.open response is in flight.
    if self.terminal_pending.get(payload.id) is Some(pending) {
      pending.push(payload)
    } else {
      self.terminal_pending[payload.id] = [payload]
    }
  }
}

///|
fn State::terminal_exited(
  self : State,
  payload : @protocol.TerminalExitPayload,
) -> Unit {
  if self.terminals.iter().find_first(tab => tab.id == payload.id) is Some(tab) {
    tab.exit_code = Some(payload.code)
  } else if self.terminal_opening > 0 {
    self.terminal_pending_exits[payload.id] = payload.code
  }
}

///|
async fn State::terminal_focus(
  self : State,
  client : @client.Client,
  focused : Bool,
) -> Unit {
  if self.terminal_visible &&
    (!focused || self.focus is Terminal) &&
    self.terminals.get(self.terminal_index) is Some(tab) {
    terminal_write(client, tab, tab.screen.focus(focused))
  }
}

///|
async fn State::close_terminals(self : State, client : @client.Client) -> Unit {
  async fn close_tabs() {
    @async.with_timeout(2000, () => {
      for tab in self.terminals {
        tab.screen.close()
        ignore(
          client.call(@commands.terminal_close, @protocol.TerminalClosePayload::{
            id: tab.id,
          }),
        ) catch {
          error if @async.is_being_cancelled() => raise error
          error =>
            self.notice = "Could not close terminal: \{error.to_string()}"
        }
      }
    }) catch {
      @async.TimeoutError => self.notice = "Terminal cleanup timed out"
      error => raise error
    }
  }
  if @async.is_being_cancelled() {
    @async.protect_from_cancel(close_tabs)
  } else {
    close_tabs()
  }
}

///|
async fn State::resize_terminals(self : State, client : @client.Client) -> Unit {
  let (cols, rows) = self.terminal_area()
  for tab in self.terminals {
    if tab.cols != cols || tab.rows != rows {
      tab.screen.resize(cols~, rows~)
      if tab.exit_code is None {
        ignore(
          client.call(@commands.terminal_resize, @protocol.TerminalResizePayload::{
            id: tab.id,
            cols,
            rows,
          }),
        )
      }
      tab.cols = cols
      tab.rows = rows
    }
  }
}
