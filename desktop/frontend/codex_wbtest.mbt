///|
test "Codex threads share the Projects section's project rows" {
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-1",
      "cwd": "/work",
      "projectRoot": "/work",
      "preview": "Codex task",
      "updatedAt": 2000,
      "turns": [],
    },
  })
  let model = { ..test_model(), codex, screen: Codex, }.with_dev(dev => {
    ..dev,
    sessions: [
      {
        id: "desktop-newer",
        title: Some("after the Codex task"),
        workspace: @interop.ChannelId::Local.test_project(),
        workspace_name: "work",
        updated_at_ms: Some(3_000_000.0),
      },
      {
        id: "desktop-older",
        title: Some("before the Codex task"),
        workspace: @interop.ChannelId::Local.test_project(),
        workspace_name: "work",
        updated_at_ms: Some(1_000_000.0),
      },
    ],
  })
  let sections = model.sidebar_component_sections(model.dev())
  // Work shows Projects, shared across both agents, above Archived.
  assert_eq(sections.length(), 2)
  inspect(sections[0].label, content="Projects")
  assert_true(!sections[0].initially_collapsed)
  guard sections[0].entries[0] is @section.Project(project) else {
    fail("expected the fixture project's row")
  }
  // The fixture's unsent OpenSeek chat is represented by its project rather
  // than a child row. Durable history still interleaves newest-first across
  // both agents.
  let order = project.conversations.map(row => row.id.conversation())
  assert_eq(order, ["desktop-newer", "codex-thread-1", "desktop-older"])
  assert_true(project.conversations[1].id.source() is @conversation.CodexLive)
  assert_true(project.conversations[1].nested)
  // With the Codex page on screen, its active task claims the activation.
  assert_eq(sections[0].activation, Some("codex-thread-1"))
  assert_eq(model.sidebar_activation(), Some((WorkMode, "codex-thread-1")))
}

///|
test "Codex sidebar selection uses the main conversation screen" {
  let dispatch = test_dispatch()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-1",
      "preview": "Shared sidebar",
      "cwd": "/work/codex-project",
      "turns": [],
    },
  })
  let wide = { ..test_model(), codex, sidebar_open: true, }
  let (_, opened) = update(dispatch, CodexOpenThread("codex-thread-1"), wide)
  assert_true(opened.screen is Codex)
  assert_true(opened.sidebar_open)
  assert_true(opened.codex.active_id() is Some("codex-thread-1"))
  assert_true(
    opened.file_panel.owner
    is Some({ channel: Local, session: "codex-thread-1", }),
  )
  let workspace = @interop.ChannelId::Local.test_resource("/work/codex-project")
  guard opened.active_checkout() is Some(active) else {
    fail("selected Codex task did not project an active checkout")
  }
  assert_eq(active.owner, {
    channel: @interop.ChannelId::Local,
    session: "codex-thread-1",
  })
  assert_eq(
    active.placement.bind(value => value.checkout_root()),
    Some(workspace),
  )
  assert_true(opened.conversation_root(opened.active()) != Some(workspace))
  assert_true(file_ctx(opened).placement is Some(@interop.WorkspaceRoot(..)))
  assert_eq(
    file_ctx(opened).placement.bind(value => value.checkout_root()),
    Some(workspace),
  )
  let opened_terminal = terminal_ctx(opened)
  inspect(opened_terminal.session, content="codex-thread-1")
  assert_true(opened_terminal.placement is Some(@interop.WorkspaceRoot(..)))
  assert_eq(
    opened_terminal.placement.bind(value => value.checkout_root()),
    Some(workspace),
  )
  assert_true(opened_terminal.connected)

  // The same input and model produce the same state; the bridge call remains
  // an opaque Cmd and is not executed inside the reducer.
  let (_, opened_again) = update(
    dispatch,
    CodexOpenThread("codex-thread-1"),
    wide,
  )
  assert_true(opened_again.screen is Codex)
  assert_true(opened_again.sidebar_open)
  assert_true(opened_again.codex.active_id() is Some("codex-thread-1"))
  assert_true(
    opened_again.file_panel.owner
    is Some({ channel: Local, session: "codex-thread-1", }),
  )
}

///|
test "Codex events from a background device cannot mutate the focused host" {
  let dispatch = test_dispatch()
  let model = test_model()
  let (_, next) = update(
    dispatch,
    Codex(
      channel=@interop.ChannelId::Remote("background"),
      @codex.Msg::status_changed({ "status": "ready" }),
    ),
    model,
  )
  assert_true(next.codex == model.codex)
  assert_eq(next.focused, model.focused)
}

///|
test "cwd-less Codex tasks keep Files unavailable and use scratch Terminal" {
  let codex = @codex.State::from_thread_snapshot({
    "thread": { "id": "codex-scratch-1", "preview": "No cwd yet", "turns": [] },
  })
  let model = { ..test_model(), codex, screen: Codex, }
  let files = file_ctx(model)
  inspect(files.owner.session, content="codex-scratch-1")
  assert_true(files.placement is None)

  // The owner remains stable for async fencing. Terminal identifies the
  // host-lazy scratch group by task id without inventing a Files directory.
  let terminal = terminal_ctx(model)
  inspect(terminal.session, content="codex-scratch-1")
  assert_true(terminal.placement is Some(@interop.Scratch(root=None)))
  assert_true(terminal.connected)
}

///|
test "Codex sidebar actions close only the narrow drawer" {
  let dispatch = test_dispatch()
  let narrow = {
    ..test_model(),
    narrow: true,
    sidebar_open: true,
    screen: Chat,
  }
  let (_, opened) = update(dispatch, OpenCodex, narrow)
  assert_true(opened.screen is Codex)
  assert_false(opened.sidebar_open)

  // A "New chat" while Codex is the default agent routes there too — and
  // still closes only the narrow drawer.
  let (_, ready) = update(
    dispatch,
    Codex(
      channel=narrow.focused,
      @codex.Msg::status_changed({ "status": "ready" }),
    ),
    { ..narrow, default_agent: CodexAgent, },
  )
  let (_, creating) = update(dispatch, NewChat, ready)
  assert_true(creating.screen is Codex)
  assert_false(creating.sidebar_open)

  // Archiving from the shared sidebar acts on that row without changing the
  // OpenSeek conversation currently occupying the main pane.
  let (_, archiving) = update(
    dispatch,
    CodexArchiveThread("codex-thread-1"),
    narrow,
  )
  assert_true(archiving.screen is Chat)
}
