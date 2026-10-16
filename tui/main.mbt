///|
enum Event {
  Input(@tty.Event)
  Notification(@protocol.Notification)
  Redraw
  StartupReady
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
let command : @argparse.Command = Command(
  "seekmoon-tui",
  about="SeekMoon terminal client. Starts a shared backend unless --connect or --server-file is supplied.",
  disable_help_flag=true,
  options=[
    OptionArg("connect", long="connect"),
    OptionArg("token", long="token", env="SEEKMOON_SERVER_TOKEN"),
    OptionArg("server-file", long="server-file"),
    OptionArg("page", long="page"),
    OptionArg("workspace", long="workspace"),
    OptionArg("session", long="session"),
    OptionArg("engine", long="engine", env="OPENSEEK_ENGINE", default_values=[
      "openseek",
    ]),
    OptionArg("frontend", long="frontend"),
    OptionArg("entry", long="entry", default_values=["index.html"]),
  ],
  flags=[
    FlagArg("demo", long="demo"),
    FlagArg("snapshot", long="snapshot"),
    FlagArg("help", long="help", short='h'),
  ],
)

///|
fn options(
  args : Array[String],
  env~ : Map[String, String] = @env.get_env_vars(),
) -> Options raise {
  let matches = command.parse(argv=args[1:], env~)
  fn value(name : String) -> String? {
    matches.values.get(name).bind(values => values.get(0))
  }
  {
    connect: value("connect"),
    token: value("token"),
    server_file: value("server-file"),
    page: value("page"),
    workspace: if value("workspace") is Some(path) {
      Some(path)
    } else {
      @env.current_dir()
    },
    session: value("session"),
    engine: value("engine").unwrap_or("openseek"),
    frontend: value("frontend"),
    entry: value("entry").unwrap_or("index.html"),
    demo: matches.flags.get("demo").unwrap_or(false) ||
    matches.flags.get("snapshot").unwrap_or(false),
    snapshot: matches.flags.get("snapshot").unwrap_or(false),
    help: matches.flags.get("help").unwrap_or(false),
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
      kind: Reasoning("demo-thinking"),
      label: "Thinking",
      text: "The existing backend owns durable sessions and connection-scoped PTYs. Both clients can use its typed command catalog.",
      sequence: Some(2),
    },
    {
      kind: Tool(
        @toolcall.Call(
          "demo-test",
          "shell",
          arguments="{\"description\":\"Run terminal tests\",\"command\":\"moon test tui --target native\"}",
          output="All terminal, transport, and transcript tests passed.",
          status=Succeeded,
        ),
      ),
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
    println(command.render_help())
    return
  }
  if opts.demo {
    let state = demo_state()
    if opts.page is Some(name) {
      match name {
        "markdown" => {
          state.active.rows.clear()
          state.active.rows.push({
            kind: Assistant,
            label: "SeekMoon",
            sequence: None,
            text: (
              #|## 验证 Validation
              #|
              #|**已完成**，使用 `moon check` 检查。
              #|
              #|| 门禁 | 结果 |
              #|| :--- | ---: |
              #|| `moon check --target native` | 通过 |
              #|| `moon test --target js` | 3705/3705 |
              #|
              #|- 保留 **粗体** 和 *强调*
              #|- [x] 中文与 English 自动换行
              #|
              #|> 缩放终端后，表格和正文会重新排版。
              #|
              #|```moonbit
              #|let message = "Hello 中文"
              #|println(message)
              #|```
              #|
              #|[MoonBit](https://www.moonbitlang.com)
            ),
          })
        }
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
        state.size = term.size()
        term.draw(state.view(state.size))
        match term.read_event() {
          Input(Key(key)) => {
            if (key.code is Escape && !(state.focus is Transcript)) ||
              (key.modifiers.ctrl() && key.code is Char('q')) {
              break
            }
            if key.code is F6 {
              state.focus = if state.focus is Transcript {
                Composer
              } else {
                Transcript
              }
              state.active.select_detail(
                0,
                state.regions(state.size).chat.height,
              )
            } else if state.detail_key(key) {
              ()
            } else if key.modifiers.ctrl() && key.code is Char('1') {
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
          Input(Mouse(mouse)) =>
            if !state.editor_toggle_mouse(mouse) && !state.detail_mouse(mouse) {
              if mouse.kind is Scroll(Up) {
                state.active.scroll.scroll_by(-3)
              }
              if mouse.kind is Scroll(Down) {
                state.active.scroll.scroll_by(3)
              }
            }
          _ => ()
        }
      }
    })
    return
  }
  configure_logging()
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
    state.loading_connection = false
    state.startup_submission = None
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
    state.loading_connection = true
    ui.spawn_bg(() => {
      try {
        state.resync(client)
        state.apply_startup(client, opts)
        if state.resync_needed {
          state.resync_needed = false
          state.resync(client)
        }
        state.busy = false
        state.loading_connection = false
        events.put(StartupReady)
      } catch {
        error if @async.is_being_cancelled() => raise error
        error => {
          state.busy = false
          state.loading_connection = false
          state.startup_submission = None
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
          StartupReady | Redraw =>
            if !state.busy &&
              !state.loading_connection &&
              state.take_startup_submission() is Some(text) {
              state.run_action(ui, events, client, text)
            }
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
    } else if self.loading_connection {
      self.defer_startup_submission(text)
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

///|
async fn State::apply_startup(
  self : State,
  client : @client.Client,
  opts : Options,
) -> Unit {
  if !self.startup_applied {
    if opts.page is Some(name) {
      self.show_page(
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
      self.unique_session(session) is Some(chat) {
      self.load_chat(client, chat)
    }
    self.startup_applied = true
  }
}
