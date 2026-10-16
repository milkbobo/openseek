///|
enum Event {
  Input(@tty.Event)
  Notification(@protocol.Notification)
  Redraw
  Failure(String)
  Disconnected(String)
}

///|
struct Options {
  connect : String?
  token : String?
  server_file : String?
  page : String?
  workspace : String?
  session : String?
  engine : String
  frontend : String?
  entry : String
  demo : Bool
  snapshot : Bool
  help : Bool
}

///|
fn options(args : Array[String]) -> Options raise {
  let mut connect = None
  let mut token = @env.get_env_var("SEEKMOON_SERVER_TOKEN")
  let mut server_file = None
  let mut page = None
  let mut workspace = @env.current_dir()
  let mut session = None
  let mut engine = @env.get_env_var("OPENSEEK_ENGINE").unwrap_or("openseek")
  let mut frontend = None
  let mut entry = "index.html"
  let mut demo = false
  let mut snapshot = false
  let mut help = false
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    match arg {
      "--demo" => demo = true
      "--snapshot" => {
        demo = true
        snapshot = true
      }
      "--help" | "-h" => help = true
      "--connect"
      | "--token"
      | "--server-file"
      | "--workspace"
      | "--session"
      | "--engine"
      | "--frontend"
      | "--entry"
      | "--page" => {
        index += 1
        guard args.get(index) is Some(value) else {
          fail("Missing value for \{arg}")
        }
        match arg {
          "--connect" => connect = Some(value)
          "--token" => token = Some(value)
          "--server-file" => server_file = Some(value)
          "--workspace" => workspace = Some(value)
          "--session" => session = Some(value)
          "--engine" => engine = value
          "--frontend" => frontend = Some(value)
          "--entry" => entry = value
          "--page" => page = Some(value)
          _ => ()
        }
      }
      _ => fail("Unknown option \{arg}; use --help")
    }
    index += 1
  }
  {
    connect,
    token,
    server_file,
    page,
    workspace,
    session,
    engine,
    frontend,
    entry,
    demo,
    snapshot,
    help,
  }
}

///|
fn demo_state() -> State {
  let state = State(Some("/workspace/seekmoon"))
  state.workspace.set_demo()
  state.active.title = "Build the terminal workspace"
  state.active.loaded = true
  state.active.rows.append([
    {
      kind: User,
      label: "You",
      text: "Add a terminal client that shares the desktop backend.",
      sequence: Some(1),
    },
    {
      kind: Reasoning,
      label: "Thinking",
      text: "The existing backend owns durable sessions and connection-scoped PTYs. Both clients can use its typed command catalog.",
      sequence: Some(2),
    },
    {
      kind: Tool,
      label: "shell_exec",
      text: "$ moon test tui --target native\nAll terminal, transport, and transcript tests passed.",
      sequence: Some(3),
    },
    {
      kind: Assistant,
      label: "SeekMoon",
      text: "The shared workspace is ready.\n\n- Durable chats stream across clients\n- Files, diffs, skills, jobs, and schedules are available\n- Real PTYs support terminal editors and full-screen programs\n\nTry /help or open a terminal with Ctrl+T.",
      sequence: Some(4),
    },
  ])
  state.notice = "Offline demo"
  state.active.status = "Completed"
  for
    title in [
      "Review the Git diff", "Explore the project", "Inspect background jobs",
    ] {
    let chat = Chat(
      {
        session: title,
        workspace: Some("/workspace/seekmoon"),
        archived: false,
      },
      title~,
    )
    state.chats[chat.key] = chat
    state.sidebar.push(chat.key)
  }
  state
}

///|
async fn main {
  let opts = options(@env.args())
  if opts.help {
    println(
      "SeekMoon terminal client\n\nseekmoon-tui [--workspace PATH] [--session ID] [--engine PATH]\n  --connect WS_URL --token TOKEN    Join an existing shared server\n  --server-file PATH               Read the server's readiness file\n  --frontend PATH [--entry FILE]    Serve desktop/browser frontend too\n  --demo                           Interactive offline example\n  --snapshot                       Print the offline example as text\n\nWithout --connect, starts a shared server for this TUI's lifetime.\nUse just seekmoon-server for a persistent server shared by multiple clients.",
    )
    return
  }
  if opts.demo {
    let state = demo_state()
    if opts.page is Some(name) {
      match name {
        "diff" => state.workspace.set_demo(diff=true)
        "editor" => state.workspace.set_demo()
        "terminal" => {
          state.size = @tui.Size(width=150, height=40)
          state.terminal_visible = true
          let (cols, rows) = state.terminal_area()
          let screen = @terminal.Screen(cols~, rows~)
          screen.feed(
            b"$ moon test tui --target native\r\n\x1b[32mAll tests passed.\x1b[0m\r\n$ git status --short\r\n M src/main.mbt\r\n$ ",
          )
          state.terminals.push({
            id: "demo-terminal",
            screen,
            session: state.active.key.session,
            cols,
            rows,
            exit_code: None,
          })
          state.focus = Terminal
        }
        "skills" => state.pages.set_demo(@pages.Skills)
        "settings" => state.pages.set_demo(@pages.Settings)
        "schedules" => state.pages.set_demo(@pages.Schedules)
        _ => fail("Unknown demo page")
      }
    }
    defer (for tab in state.terminals {
      tab.screen.close()
    })
    if opts.snapshot {
      println(state.view(@tui.Size(width=150, height=40)).to_text())
      return
    }
    @tui.with_terminal(mouse=true, term => {
      for ;; {
        term.draw(state.view(term.size()))
        match term.read_event() {
          Input(Key(key)) => {
            if key.code is Escape ||
              (key.modifiers.ctrl() && key.code is Char('q')) {
              break
            }
            if key.modifiers.ctrl() && key.code is Char('1') {
              state.pages.close()
            } else if key.modifiers.ctrl() && key.code is Char('2') {
              state.pages.set_demo(@pages.Skills)
            } else if key.modifiers.ctrl() && key.code is Char('3') {
              state.pages.set_demo(@pages.Schedules)
            } else if key.modifiers.ctrl() && key.code is Char('4') {
              state.pages.set_demo(@pages.Settings)
            } else if key.code is PageUp {
              state.active.scroll.page_up()
            } else if key.code is PageDown {
              state.active.scroll.page_down()
            } else {
              ignore(state.active.draft.key(key))
            }
          }
          _ => ()
        }
      }
    })
    return
  }
  @async.with_task_group(group => {
    let (url, token) = if opts.server_file is Some(path) {
      let ready = @json.parse(@fs.read_file(path).text())
      guard ready is { "url": String(url), "token": String(token), .. } else {
        fail("Invalid server readiness file")
      }
      (url, token)
    } else if opts.connect is Some(url) {
      guard opts.token is Some(token) else {
        fail("Use --token or SEEKMOON_SERVER_TOKEN with --connect")
      }
      (url, token)
    } else {
      let server = @host.Server::from_environment(engine=opts.engine)
      group.spawn_bg(() => server.run(root?=opts.frontend, entry=opts.entry))
      (server.url(), server.token())
    }
    let state = State(opts.workspace)
    state.server_url = url
    @tui.with_terminal(mouse=true, term => {
      @async.with_task_group(input_owner => {
        let inputs : @aqueue.Queue[@tty.Event] = Queue(kind=Blocking(256))
        input_owner.spawn_bg(() => {
          for ;; {
            inputs.put(term.read_event())
          }
        })
        for ;; {
          let quit = run_connection(state, term, inputs, opts, url, token) catch {
            error if @async.is_being_cancelled() => raise error
            error => {
              state.notice = "Disconnected: \{error.to_string()} · retrying"
              false
            }
          }
          if quit {
            break
          }
          state.busy = false
          state.size = term.size()
          term.draw(state.view(state.size))
          if @async.with_timeout_opt(1000, () => inputs.get())
            is Some(Input(Key(key))) &&
            key.modifiers.ctrl() &&
            key.code is Char('q') {
            break
          }
        }
        input_owner.return_immediately(())
      })
    })
    group.return_immediately(())
  })
}

///|
async fn run_connection(
  state : State,
  term : @tui.Terminal,
  inputs : @aqueue.Queue[@tty.Event],
  opts : Options,
  initial_url : String,
  initial_token : String,
) -> Bool {
  let (url, token) = if opts.server_file is Some(path) {
    let ready = @json.parse(@fs.read_file(path).text())
    guard ready is { "url": String(url), "token": String(token), .. } else {
      fail("Invalid server readiness file")
    }
    (url, token)
  } else {
    (initial_url, initial_token)
  }
  state.server_url = url
  let client = @async.with_timeout(5000, () => {
    @client.Client::connect(url, token~)
  })
  defer client.close()
  state.begin_connection()
  defer {
    state.busy = false
  }
  @async.with_task_group(ui => {
    let events : @aqueue.Queue[Event] = Queue(kind=Blocking(1024))
    ui.spawn_bg(() => {
      client.run() catch {
        error if @async.is_being_cancelled() => raise error
        error => events.put(Disconnected(error.to_string()))
      }
    })
    ui.spawn_bg(() => {
      try {
        for ;; {
          events.put(Notification(client.receive()))
        }
      } catch {
        error if @async.is_being_cancelled() => raise error
        error => events.put(Disconnected(error.to_string()))
      }
    })
    ui.spawn_bg(() => {
      for ;; {
        events.put(Input(inputs.get()))
      }
    })
    state.busy = true
    ui.spawn_bg(() => {
      defer {
        state.busy = false
      }
      try {
        state.resync(client)
        if opts.page is Some(name) {
          state.show_page(
            client,
            Some(
              match name {
                "skills" => @pages.Skills
                "settings" => @pages.Settings
                "schedules" => @pages.Schedules
                _ => fail("--page must be skills, settings, or schedules")
              },
            ),
          )
        }
        if opts.session is Some(session) &&
          state.unique_session(session) is Some(chat) {
          state.load_chat(client, chat)
        }
        if state.resync_needed {
          state.resync_needed = false
          state.resync(client)
        }
        state.busy = false
        events.put(Redraw)
      } catch {
        error if @async.is_being_cancelled() => raise error
        error => {
          state.busy = false
          events.put(Failure(error.to_string()))
        }
      }
    })
    for ;; {
      state.size = term.size()
      term.draw(state.view(state.size))
      let event = events.get()
      state.size = term.size()
      try {
        match event {
          Input(Input(Key(key))) => {
            if key.modifiers.ctrl() && key.code is Char('q') {
              state.close_terminals(client)
              ui.return_immediately(true)
            }
            if state.key(client, key) {
              state.run_action(ui, events, client, state.active.draft.text())
            }
          }
          Input(Input(Paste(text))) =>
            if state.focus is Terminal &&
              state.terminal_visible &&
              state.terminals.get(state.terminal_index) is Some(tab) {
              terminal_write(client, tab, tab.screen.paste(text))
            } else if state.focus is Pages && state.pages.page() is Some(_) {
              ignore(state.pages.paste(text))
            } else if state.focus is Workspace {
              ignore(state.workspace.paste(text))
            } else if state.focus is Sidebar {
              ignore(state.sidebar_paste(text))
            } else if state.focus is Composer {
              state.active.draft.insert(text)
            }
          Input(Input(Mouse(mouse))) => state.mouse(client, Some(term), mouse)
          Input(Input(FocusIn)) => state.terminal_focus(client, true)
          Input(Input(FocusOut)) => state.terminal_focus(client, false)
          Input(_) => state.resize_terminals(client)
          Notification(TerminalOutput(payload)) =>
            state.terminal_output(client, payload)
          Notification(notification) => {
            if notification is SessionChanged(change) {
              state.session_changed(change)
            }
            state.notification(notification)
            state.pages.notification(client, notification, state.context())
            state.workspace.notification(client, notification)
            if notification is AgentConnected(_) ||
              notification is SessionChanged(_) ||
              notification is WorkspaceChanged(_) ||
              state.active.needs_reload {
              state.run_action(ui, events, client, "/resync-internal")
            }
          }
          Disconnected(message) => {
            state.notice = "Disconnected: \{message} · retrying"
            state.close_terminals(client)
            state.terminals.clear()
            state.terminal_pending.clear()
            state.terminal_pending_exits.clear()
            state.terminal_visible = false
            state.focus = Composer
            ui.return_immediately(false)
          }
          Failure(message) => {
            state.notice = message
            state.active.notice(message, error=true)
          }
          Redraw => ()
        }
      } catch {
        error if @async.is_being_cancelled() => raise error
        error => {
          state.notice = error.to_string()
          state.active.notice(error.to_string(), error=true)
        }
      }
    }
  })
}

///|
fn[G] State::run_action(
  self : State,
  group : @async.TaskGroup[G],
  events : @aqueue.Queue[Event],
  client : @client.Client,
  text : String,
) -> Unit {
  if self.busy {
    if text == "/resync-internal" {
      self.resync_needed = true
    }
    return
  }
  if text.is_blank() && self.active.attachments.is_empty() {
    return
  }
  self.busy = true
  let source_chat = self.active
  group.spawn_bg(() => {
    try {
      if text == "/resync-internal" {
        self.resync(client)
      } else {
        self.execute(client, text)
      }
      if text.has_prefix("/") || text.has_prefix("!") {
        if source_chat.draft.text() == text {
          source_chat.draft.clear()
        }
      }
      if self.resync_needed {
        self.resync_needed = false
        self.resync(client)
      }
    } catch {
      error if @async.is_being_cancelled() => raise error
      error => {
        self.notice = error.to_string()
        self.active.notice(error.to_string(), error=true)
      }
    }
    self.busy = false
    events.put(Redraw)
  })
}
