///|
async test "terminal output and exit before open reply are retained and acknowledged" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let port = server.addr.port()
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let release_reply : @async.Queue[Unit] = Queue(kind=Blocking(1))
      group.spawn_bg(() => {
        let (connection, _) = server.accept()
        defer connection.close()
        let request = connection.read_request()
        let socket = @websocket.Conn::from_http_server(request, connection)
        defer socket.close()
        let open = @json.parse(socket.recv().read_all().text())
        guard open is Object(fields) && fields.get("id") is Some(open_id) else {
          fail("missing terminal open request")
        }
        assert_eq(fields.get("method"), Some(Json("terminal.open")))
        guard fields.get("params") is Some(Object(params)) else {
          fail("missing terminal open parameters")
        }
        assert_eq(params.get("session"), Some(Json("codex-terminal-thread")))
        socket.send_text(
          (
            {
              "jsonrpc": "2.0",
              "method": "terminal.output",
              "params": {
                "id": "early-pty",
                "sequence": 1,
                "data": @base64.encode(b"\x1b[31mearly PTY\x1b[0m"),
              },
            } : Json).stringify(),
        )
        socket.send_text(
          (
            {
              "jsonrpc": "2.0",
              "method": "terminal.exit",
              "params": { "id": "early-pty", "code": 7 },
            } : Json).stringify(),
        )
        release_reply.get()
        socket.send_text(
          (
            { "jsonrpc": "2.0", "id": open_id, "result": { "id": "early-pty" } } :
            Json).stringify(),
        )
        let ack = @json.parse(socket.recv().read_all().text())
        guard ack is Object(fields) && fields.get("id") is Some(ack_id) else {
          fail("missing terminal acknowledgement")
        }
        assert_eq(fields.get("method"), Some(Json("terminal.ack")))
        assert_eq(
          fields.get("params"),
          Some(({ "id": "early-pty", "sequence": 1 } : Json)),
        )
        socket.send_text(
          (
            { "jsonrpc": "2.0", "id": ack_id, "result": Json::empty_object() } :
            Json).stringify(),
        )
        let close = @json.parse(socket.recv().read_all().text())
        guard close is Object(fields) && fields.get("id") is Some(close_id) else {
          fail("missing terminal close request")
        }
        assert_eq(fields.get("method"), Some(Json("terminal.close")))
        socket.send_text(
          (
            { "jsonrpc": "2.0", "id": close_id, "result": Json::empty_object() } :
            Json).stringify(),
        )
        ignore(socket.recv())
      })
      let client = @client.Client::connect(
        "ws://127.0.0.1:\{port}/v1/devices/host/ws",
        token="test",
      )
      defer client.close()
      group.spawn_bg(allow_failure=true, () => client.run())
      let state = State(None)
      state.active.key = {
        ..state.active.key,
        session: "codex:codex-terminal-thread",
      }
      let opening = group.spawn(() => {
        state.open_terminal(client, Some("printf early"))
      })
      guard client.receive() is TerminalOutput(payload) else {
        fail("missing early output")
      }
      state.terminal_output(client, payload)
      guard client.receive() is TerminalExit(exit) else {
        fail("missing early exit")
      }
      state.terminal_exited(exit)
      assert_eq(state.terminal_pending.length(), 1)
      assert_eq(state.terminal_opening, 1)
      release_reply.put(())
      opening.wait()
      assert_eq(state.terminal_opening, 0)
      assert_true(state.terminal_pending.is_empty())
      assert_true(state.terminal_pending_exits.is_empty())
      guard state.terminals.get(0) is Some(tab) else {
        fail("terminal was not attached")
      }
      assert_eq(tab.exit_code, Some(7))
      let frame = @tui.Frame(width=tab.cols, height=tab.rows)
      tab.screen.draw(frame, frame.area())
      assert_true(frame.to_text().contains("early PTY"))
      state.close_terminals(client)
      client.close()
      group.return_immediately(())
    })
  })
}

///|
async fn with_terminal_peer(
  serve : async (@websocket.Conn) -> Unit,
  run : async (@client.Client) -> Unit,
) -> Unit {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (connection, _) = server.accept()
        defer connection.close()
        let request = connection.read_request()
        let socket = @websocket.Conn::from_http_server(request, connection)
        defer socket.close()
        serve(socket)
        ignore(socket.recv())
      })
      let client = @client.Client::connect(
        "ws://127.0.0.1:\{server.addr.port()}/v1/devices/host/ws",
        token="test",
      )
      defer client.close()
      group.spawn_bg(allow_failure=true, () => client.run())
      run(client)
      client.close()
      group.return_immediately(())
    })
  })
}

///|
async fn terminal_request(
  socket : @websocket.Conn,
  method_ : String,
) -> (Json, Json) {
  let envelope = @json.parse(socket.recv().read_all().text())
  guard envelope is Object(fields) &&
    fields.get("id") is Some(id) &&
    fields.get("params") is Some(params) else {
    fail("missing terminal request")
  }
  assert_eq(fields.get("method"), Some(Json(method_)))
  (id, params)
}

///|
async fn terminal_reply(socket : @websocket.Conn, id : Json) -> Unit {
  socket.send_text(
    ({ "jsonrpc": "2.0", "id": id, "result": Json::empty_object() } : Json).stringify(),
  )
}

///|
async test "closing a terminal preserves a tab selected while its close RPC is pending" {
  let close_seen : @async.Queue[Unit] = Queue(kind=Blocking(1))
  let release_close : @async.Queue[Unit] = Queue(kind=Blocking(1))
  with_terminal_peer(
    socket => {
      let (id, params) = terminal_request(socket, "terminal.close")
      assert_eq(params, ({ "id": "old" } : Json))
      close_seen.put(())
      release_close.get()
      terminal_reply(socket, id)
      let (id, params) = terminal_request(socket, "terminal.close")
      assert_eq(params, ({ "id": "new" } : Json))
      terminal_reply(socket, id)
    },
    client => {
      let state = State(None)
      state.terminals.push({
        id: "old",
        screen: @terminal.Screen(cols=20, rows=5),
        session: "s",
        cols: 20,
        rows: 5,
        exit_code: None,
      })
      state.terminal_visible = true
      state.focus = Terminal
      @async.with_task_group(group => {
        let closing = group.spawn(() => state.close_terminal(client))
        close_seen.get()
        state.terminals.push({
          id: "new",
          screen: @terminal.Screen(cols=20, rows=5),
          session: "s",
          cols: 20,
          rows: 5,
          exit_code: None,
        })
        state.terminal_index = 1
        release_close.put(())
        closing.wait()
      })
      assert_eq(state.terminals.length(), 1)
      assert_eq(state.terminals[0].id, "new")
      assert_eq(state.terminal_index, 0)
      state.close_terminals(client)
    },
  )
}

///|
async test "failed PTY resize remains eligible for the next resize retry" {
  with_terminal_peer(
    socket => {
      let (id, first) = terminal_request(socket, "terminal.resize")
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32000, "message": "temporary resize failure" },
          } : Json).stringify(),
      )
      let (id, second) = terminal_request(socket, "terminal.resize")
      assert_eq(first, second)
      terminal_reply(socket, id)
      let (id, _) = terminal_request(socket, "terminal.close")
      terminal_reply(socket, id)
    },
    client => {
      let state = State(None)
      state.size = @tui.Size(width=120, height=40)
      state.terminal_visible = true
      state.terminals.push({
        id: "resize",
        screen: @terminal.Screen(cols=20, rows=5),
        session: "s",
        cols: 20,
        rows: 5,
        exit_code: None,
      })
      try state.resize_terminals(client) catch {
        @client.ClientError::Rpc(..) => ()
        error => raise error
      } noraise {
        _ => fail("expected the injected resize failure")
      }
      assert_eq(state.terminals[0].cols, 20)
      assert_eq(state.terminals[0].rows, 5)
      state.resize_terminals(client)
      let (cols, rows) = state.terminal_area()
      assert_eq(state.terminals[0].cols, cols)
      assert_eq(state.terminals[0].rows, rows)
      state.close_terminals(client)
    },
  )
}

///|
async test "one-based mouse cells reach first and last terminal cells only" {
  with_terminal_peer(
    socket => {
      let (id, params) = terminal_request(socket, "terminal.input")
      assert_eq(
        params,
        (
          { "id": "mouse", "data_base64": @base64.encode(b"\x1b[<0;1;1M") } :
          Json),
      )
      terminal_reply(socket, id)
      let (id, params) = terminal_request(socket, "terminal.input")
      assert_eq(
        params,
        (
          { "id": "mouse", "data_base64": @base64.encode(b"\x1b[<0;96;12M") } :
          Json),
      )
      terminal_reply(socket, id)
      let (id, _) = terminal_request(socket, "terminal.close")
      terminal_reply(socket, id)
    },
    client => {
      let state = State(None)
      state.size = @tui.Size(width=120, height=40)
      state.terminal_visible = true
      let area = state.regions(state.size).terminal
      let screen = @terminal.Screen(cols=area.width, rows=area.height)
      screen.feed(b"\x1b[?1000h\x1b[?1006h")
      state.terminals.push({
        id: "mouse",
        screen,
        session: "s",
        cols: area.width,
        rows: area.height,
        exit_code: None,
      })
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(Press(Left), area.row + 1, area.col + 1),
      )
      assert_true(state.focus is Terminal)
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(
          Press(Left),
          area.row + area.height,
          area.col + area.width,
        ),
      )
      // The footer immediately after the sheet is outside the PTY.
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(
          Press(Left),
          area.row + area.height + 1,
          area.col + 1,
        ),
      )
      state.close_terminals(client)
    },
  )
}

///|
async test "sidebar navigation respects pane bounds and wheel events preserve vertical axes" {
  with_terminal_peer(
    socket => {
      let (id, _) = terminal_request(socket, "terminal.close")
      terminal_reply(socket, id)
    },
    client => {
      let tools = demo_state()
      tools.size = @tui.Size(width=120, height=40)
      tools.active.draft.set_text("unsent draft")
      ignore(tools.view(tools.size))
      let area = tools.regions(tools.size).chat
      let layout = tools.active.layout.unwrap()
      let (_, header) = layout.tool_headers[0]
      let y = header - tools.active.scroll.offset() + area.row + 1
      let x = area.col + 2
      tools.mouse(client, None, @input.MouseEvent::new(Press(Left), y, x))
      tools.mouse(client, None, @input.MouseEvent::new(Release(Left), y, x))
      assert_true(tools.active.expanded_tools.contains("demo-test"))
      assert_true(tools.focus is Transcript)
      assert_true(tools.view(tools.size).to_text().contains("Arguments"))
      assert_true(!tools.key(client, @input.KeyEvent::new(Enter)))
      assert_true(!tools.active.expanded_tools.contains("demo-test"))
      assert_eq(tools.active.draft.text(), "unsent draft")
      ignore(tools.view(tools.size))
      // Dragging over a header is selection, not expansion, even if it ends
      // back at the original cell.
      tools.mouse(client, None, @input.MouseEvent::new(Press(Left), y, x))
      tools.mouse(client, None, @input.MouseEvent::new(Drag(Left), y, x + 3))
      tools.mouse(client, None, @input.MouseEvent::new(Release(Left), y, x))
      assert_true(!tools.active.expanded_tools.contains("demo-test"))
      tools.focus = Composer
      assert_true(!tools.key(client, @input.KeyEvent::new(F6)))
      assert_true(tools.focus is Transcript)
      assert_true(!tools.key(client, @input.KeyEvent::new(Enter)))
      assert_true(tools.active.expanded_tools.contains("demo-test"))
      assert_true(!tools.key(client, @input.KeyEvent::new(Escape)))
      assert_true(tools.focus is Composer)
      let state = State(None)
      state.size = @tui.Size(width=120, height=40)
      state.terminals.push({
        id: "sentinel",
        screen: @terminal.Screen(cols=20, rows=5),
        session: "s",
        cols: 20,
        rows: 5,
        exit_code: None,
      })
      let nav = state.regions(state.size).left_nav
      state.focus = Sidebar
      state.panel("Before", [])
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(Press(Left), nav.row + 1, nav.col + 1),
      )
      assert_true(state.focus is Composer)
      assert_eq(state.panel_title, None)
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(
          Press(Left),
          nav.row + nav.height,
          nav.col + nav.width,
        ),
      )
      assert_eq(state.panel_title, Some("Connection"))
      state.panel("Outside", [])
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(
          Press(Left),
          nav.row + nav.height + 1,
          nav.col + 1,
        ),
      )
      assert_eq(state.panel_title, Some("Outside"))
      // A horizontal component must not undo a slow vertical wheel gesture.
      state.panel_title = None
      for index in 0..<80 {
        state.active.notice("Line \{index}: 中文 text")
      }
      ignore(state.view(state.size))
      state.active.scroll.to_top()
      state.active.scroll.scroll_by(12)
      let chat = state.regions(state.size).chat
      for direction in [@input.MouseScroll::Left, @input.MouseScroll::Right] {
        let before = state.view(state.size).to_text()
        let offset = state.active.scroll.offset()
        state.mouse(
          client,
          None,
          @input.MouseEvent::new(Scroll(direction), chat.row + 1, chat.col + 1),
        )
        assert_eq(state.active.scroll.offset(), offset)
        assert_eq(state.view(state.size).to_text(), before)
      }
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(Scroll(Up), chat.row + 1, chat.col + 1),
      )
      assert_eq(state.active.scroll.offset(), 9)
      state.mouse(
        client,
        None,
        @input.MouseEvent::new(Scroll(Down), chat.row + 1, chat.col + 1),
      )
      assert_eq(state.active.scroll.offset(), 12)
      state.panel("Help", Array::makei(80, i => "Help line \{i}"))
      ignore(state.view(state.size))
      state.panel_scroll.scroll_by(12)
      for direction in [@input.MouseScroll::Left, @input.MouseScroll::Right] {
        state.mouse(
          client,
          None,
          @input.MouseEvent::new(Scroll(direction), chat.row + 1, chat.col + 1),
        )
        assert_eq(state.panel_scroll.offset(), 12)
      }
      for _ in 0..<20 {
        state.new_chat(None)
      }
      state.sidebar_cursor = 5
      let sidebar = state.regions(state.size).left_chats
      for direction in [@input.MouseScroll::Left, @input.MouseScroll::Right] {
        state.mouse(
          client,
          None,
          @input.MouseEvent::new(
            Scroll(direction),
            sidebar.row + 1,
            sidebar.col + 1,
          ),
        )
        assert_eq(state.sidebar_cursor, 5)
      }
      state.pages.set_demo(@pages.Settings)
      for direction in [@input.MouseScroll::Left, @input.MouseScroll::Right] {
        let before = state.view(state.size).to_text()
        state.mouse(
          client,
          None,
          @input.MouseEvent::new(Scroll(direction), chat.row + 1, chat.col + 1),
        )
        assert_eq(state.view(state.size).to_text(), before)
      }
      state.close_terminals(client)
    },
  )
}
