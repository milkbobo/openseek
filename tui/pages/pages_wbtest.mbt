///|
fn context() -> @workbench.Context {
  {
    session: "example",
    workspace: Some("/workspace/example"),
    model: "deepseek-v4-pro",
    run_id: None,
    archived: false,
  }
}

///|
test "Skills is an interactive catalog page with search tabs and selectable cards" {
  let state = State()
  state.set_demo(Skills)
  let frame = @tui.Frame(width=100, height=30)
  state.draw(frame, frame.area())
  let rendered = frame.to_text()
  assert_true(rendered.contains("Skills"))
  assert_true(rendered.contains("Installed"))
  assert_true(rendered.contains("Catalog"))
  assert_true(rendered.contains("Search skills"))
  assert_true(rendered.contains("Code review"))
  assert_true(state.hits.any(hit => hit.action is SkillTab(true)))
  state.query.set_text("project")
  assert_eq(state.visible_installed().length(), 1)
  assert_eq(state.visible_installed()[0].name, "Project guide")
}

///|
test "Settings renders provider and editable preferences with masked secrets" {
  let state = State()
  state.set_demo(Settings)
  state.key.set_text("private-test-token")
  state.focus = 2
  let frame = @tui.Frame(width=90, height=25)
  state.draw(frame, frame.area())
  let rendered = frame.to_text()
  assert_true(rendered.contains("Settings"))
  assert_true(rendered.contains("DeepSeek"))
  assert_true(rendered.contains("API key"))
  assert_true(rendered.contains("Save settings"))
  assert_true(!rendered.contains("private-test-token"))
  assert_true(state.hits.any(hit => hit.action is SaveSettings))
}

///|
test "Settings exposes account remote and application categories with actual actions" {
  let state = State()
  state.set_demo(Settings)
  for section in 0..<4 {
    state.settings_section = section
    state.settings_details = ["Example shared server status"]
    let frame = @tui.Frame(width=105, height=30)
    state.draw(frame, frame.area())
    assert_eq(
      state.hits.filter(hit => hit.action is SettingsSection(_)).length(),
      4,
    )
    match section {
      0 => assert_true(state.hits.any(hit => hit.action is SaveSettings))
      1 => {
        assert_true(frame.to_text().contains("Codex account"))
        assert_true(state.hits.any(hit => hit.action is CodexLogin))
        assert_true(state.hits.any(hit => hit.action is CodexConfig))
      }
      2 => {
        assert_true(frame.to_text().contains("Remote control"))
        assert_true(state.hits.any(hit => hit.action is RemoteConnect))
        assert_true(state.hits.any(hit => hit.action is RemoteDisconnect))
      }
      _ => assert_true(frame.to_text().contains("Example shared server status"))
    }
  }
}

///|
test "Codex authorization URLs wrap completely and account focus remains visible" {
  let state = State()
  state.set_demo(Settings)
  state.settings_section = 1
  let url = "https://auth.example.test/" + "a".repeat(140) + "?state=login"
  state.settings_details = [url]
  assert_eq(state.settings_lines(40).join(""), url)
  state.focus = 3
  state.reveal_focus = true
  let frame = @tui.Frame(width=90, height=20)
  let area = @tui.Rect(row=1, col=24, width=65, height=10)
  state.draw(frame, area)
  assert_true(state.hits.any(hit => hit.action is CodexConfig))
}

///|
test "Schedules renders cards with actual lifecycle controls" {
  let state = State()
  state.set_demo(Schedules)
  let frame = @tui.Frame(width=100, height=30)
  state.draw(frame, frame.area())
  let rendered = frame.to_text()
  assert_true(rendered.contains("Scheduled tasks"))
  assert_true(rendered.contains("Review the workspace"))
  assert_true(rendered.contains("Every 60 min"))
  assert_true(rendered.contains("Run"))
  assert_true(rendered.contains("Pause"))
  assert_true(rendered.contains("Edit"))
  assert_true(state.hits.any(hit => hit.action is ScheduleAction("run")))
}

///|
test "schedule form edits actual fields and emits the desktop timing contract" {
  let state = State()
  state.set_demo(Schedules)
  state.new_form(context())
  guard state.form is Some(form) else { fail("Expected form") }
  form.name.set_text("Review 月")
  form.task.set_text("Check the build")
  form.minutes.set_text("15")
  form.timeout.set_text("20")
  let every = form.payload(false, 1000L)
  assert_eq(every.spec.timing, Every(15))
  assert_eq(every.spec.name, "Review 月")
  assert_eq(every.spec.workspace, Some("/workspace/example"))
  form.once = true
  let once = form.payload(true, 1000L)
  assert_eq(once.spec.timing, Once(901000L))
  assert_true(once.run_now)
  form.once_at = Some(1000000L)
  assert_eq(form.payload(false, 2000L).spec.timing, Once(1000000L))
  let frame = @tui.Frame(width=100, height=30)
  state.draw(frame, frame.area())
  assert_true(frame.to_text().contains("New scheduled task"))
  assert_true(frame.to_text().contains("Save and run"))
}

///|
test "page controls stay within the assigned central region" {
  let state = State()
  state.set_demo(Settings)
  let frame = @tui.Frame(width=120, height=35)
  let area = @tui.Rect(row=2, col=30, width=70, height=23)
  state.draw(frame, area)
  assert_true(
    state.hits.all(hit => {
      hit.area.row >= area.row &&
      hit.area.row < area.row + area.height &&
      hit.area.col >= area.col
    }),
  )
  assert_true(
    frame.to_text().split("\n").next().unwrap_or("").trim().is_empty(),
  )
}

///|
async test "keyboard editing and schedule Save use the real typed native client" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(allow_failure=true, () => {
        let (connection, _) = server.accept()
        defer connection.close()
        let request = connection.read_request()
        let socket = @websocket.Conn::from_http_server(request, connection)
        defer socket.close()
        let envelope = @json.parse(socket.recv().read_all().text())
        guard envelope is Object(fields) &&
          fields.get("id") is Some(id) &&
          fields.get("params") is Some(params) else {
          fail("Expected a schedule request")
        }
        assert_eq(fields.get("method"), Some(Json("schedules.save")))
        let payload : @protocol.ScheduleSavePayload = @json.from_json(params)
        assert_eq(payload.spec.name, "Keyboard task")
        assert_eq(payload.spec.task, "Check build")
        assert_eq(payload.spec.workspace, Some("/workspace/example"))
        socket.send_text(
          (
            {
              "jsonrpc": "2.0",
              "id": id,
              "result": { "entries": [], "runs": [] },
            } : Json).stringify(),
        )
        ignore(socket.recv())
      })
      let client = @client.Client::connect(
        "ws://127.0.0.1:\{server.addr.port()}/v1/devices/host/ws",
        token="page-test",
      )
      defer client.close()
      group.spawn_bg(allow_failure=true, () => client.run())
      let state = State()
      state.set_demo(Skills)
      let frame = @tui.Frame(width=100, height=30)
      state.draw(frame, frame.area())
      guard state.hits.iter().find_first(hit => hit.action is SkillTab(true))
        is Some(catalog) else {
        fail("Expected catalog button")
      }
      ignore(
        state.mouse(
          client,
          @input.MouseEvent::new(
            Press(Left),
            catalog.area.row,
            catalog.area.col + 1,
          ),
          context(),
        ),
      )
      assert_true(!state.catalog_tab)
      ignore(
        state.mouse(
          client,
          @input.MouseEvent::new(
            Press(Left),
            catalog.area.row + 1,
            catalog.area.col + 1,
          ),
          context(),
        ),
      )
      assert_true(state.catalog_tab)
      guard state.hits.iter().find_first(hit => hit.action is SkillTab(false))
        is Some(installed) else {
        fail("Expected installed button")
      }
      ignore(
        state.mouse(
          client,
          @input.MouseEvent::new(
            Press(Left),
            installed.area.row + 1,
            installed.area.col + 1,
          ),
          context(),
        ),
      )
      assert_true(!state.catalog_tab)
      for ch in "project" {
        ignore(
          state.key(
            client,
            @input.KeyEvent::new(Char(ch), text=ch.to_string()),
            context(),
          ),
        )
      }
      assert_eq(state.visible_installed().length(), 1)
      ignore(state.key(client, @input.KeyEvent::new(Tab), context()))
      ignore(state.key(client, @input.KeyEvent::new(Right), context()))
      assert_true(state.catalog_tab)
      state.set_demo(Settings)
      ignore(state.key(client, @input.KeyEvent::new(Right), context()))
      assert_eq(state.provider, 1)
      ignore(state.key(client, @input.KeyEvent::new(Tab), context()))
      for ch in "endpoint" {
        ignore(
          state.key(
            client,
            @input.KeyEvent::new(Char(ch), text=ch.to_string()),
            context(),
          ),
        )
      }
      assert_eq(state.url.text(), "endpoint")
      state.set_demo(Schedules)
      ignore(state.key(client, @input.KeyEvent::new(Char('n')), context()))
      for ch in "Keyboard task" {
        ignore(
          state.key(
            client,
            @input.KeyEvent::new(Char(ch), text=ch.to_string()),
            context(),
          ),
        )
      }
      ignore(state.key(client, @input.KeyEvent::new(Tab), context()))
      ignore(state.key(client, @input.KeyEvent::new(Tab), context()))
      for ch in "Check build" {
        ignore(
          state.key(
            client,
            @input.KeyEvent::new(Char(ch), text=ch.to_string()),
            context(),
          ),
        )
      }
      ignore(
        state.key(
          client,
          @input.KeyEvent::new(
            Char('s'),
            modifiers=@input.KeyModifiers::new(ctrl=true),
          ),
          context(),
        ),
      )
      assert_true(state.form is None)
      assert_eq(state.notice, "Schedule saved")
      group.return_immediately(())
    })
  })
}

///|
test "focused settings controls reveal themselves above a bottom terminal sheet" {
  let state = State()
  state.set_demo(Settings)
  state.focus = 4
  state.reveal_focus = true
  let frame = @tui.Frame(width=100, height=35)
  let area = @tui.Rect(row=2, col=25, width=70, height=13)
  state.draw(frame, area)
  assert_true(state.page_offset > 0)
  assert_true(state.hits.any(hit => hit.action is SaveSettings))
  assert_true(
    state.hits.all(hit => {
      hit.area.row >= area.row && hit.area.row < area.row + area.height
    }),
  )
}

///|
test "paste targets the focused page field without entering the chat composer" {
  let state = State()
  state.set_demo(Schedules)
  state.new_form(context())
  state.focus = 2
  assert_true(state.paste("Check the build\nReport failures"))
  guard state.form is Some(form) else { fail("Expected form") }
  assert_eq(form.task.text(), "Check the build\nReport failures")
  state.close()
  assert_true(!state.paste("chat text"))
}
