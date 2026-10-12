///|
fn encoded_start_workspace(conv : Conversation) -> String? {
  let payload = start_payload(
    "continue",
    DsPro,
    ReasoningMax,
    "1000",
    conv.session_id,
    "test-submission",
    workspace=conv.project(),
  )
  let json = payload.to_json()
  guard json is Object(fields) else { return None }
  @jsonx.json_text(fields, "workspace")
}

///|
test "sessions loaded replaces the sidebar list" {
  let dispatch = test_dispatch()
  let items : Array[@transcript.SessionListItem] = [
    {
      id: "desktop-a",
      title: Some("first question"),
      workspace: @interop.ChannelId::Local.test_project(),
      workspace_name: "",
      updated_at_ms: None,
    },
  ]
  let (_, once) = update(dispatch, sessions_loaded(items), test_model())
  let (_, twice) = update(dispatch, sessions_loaded(items), test_model())
  inspect(once.dev().sessions.length(), content="1")
  inspect(once.dev().sessions[0].id, content="desktop-a")
  inspect(twice.dev().sessions.length(), content="1")
}

///|
test "session list assigns a commit-first conversation to its durable workspace" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/foreign")
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-foreign",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("arrived before the list")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    test_model(),
  )
  guard committed.find_conversation(
      @interop.ChannelId::Local,
      "desktop-foreign",
    )
    is Some(provisional) else {
    fail("commit did not materialize its conversation")
  }
  // The commit's own store places it immediately; the listing that follows
  // is what moves it to the project the host groups it under.
  assert_eq(
    provisional.workspace,
    Project(root=@interop.ChannelId::Local.test_project()),
  )
  let (_, listed) = update(
    dispatch,
    sessions_loaded(
      [
        {
          id: "desktop-foreign",
          title: Some("arrived before the list"),
          workspace,
          workspace_name: "foreign",
          updated_at_ms: None,
        },
      ],
      request_generation=committed.dev().sessions_request_generation,
    ),
    committed.activate(
      @interop.ChannelId::Local,
      "desktop-foreign",
      @interop.ChannelId::Local.test_project(),
    ),
  )
  guard listed.find_conversation(@interop.ChannelId::Local, "desktop-foreign")
    is Some(reconciled) else {
    fail("listed conversation disappeared")
  }
  assert_eq(reconciled.workspace, Project(root=workspace))
  assert_eq(listed.dev().active_project, Some(workspace))
  assert_true(encoded_start_workspace(reconciled) is Some("/work/foreign"))
}

///|
test "a rooted commit places its conversation without waiting for the list" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/foreign")
  let store = @interop.ChannelId::Local.test_resource("/work/foreign/.openseek")
  let model = test_model().with_dev(dev => { ..dev, projects: [workspace], })
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-foreign",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("arrived before the list")]),
        submission_id: None,
      }),
      session_root=store,
    ),
    model,
  )
  guard committed.find_conversation(
      @interop.ChannelId::Local,
      "desktop-foreign",
    )
    is Some(placed) else {
    fail("rooted commit did not materialize its conversation")
  }
  assert_eq(placed.workspace, Project(root=workspace))
  // A registered project's own store is matched exactly rather than guessed
  // from a missing listing.
  let (_, registered) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-registered",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("hi")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    committed,
  )
  guard registered.find_conversation(
      @interop.ChannelId::Local,
      "desktop-registered",
    )
    is Some(known) else {
    fail("rooted commit for a registered store did not materialize")
  }
  assert_eq(
    known.workspace,
    Project(root=@interop.ChannelId::Local.test_project()),
  )
  // The projects registry reply may still be in flight on a fresh
  // connection: a store outside the mirrored registry is still a project
  // store, and its layout (`<project>/.openseek`) names the project.
  let (_, unseen) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-unseen",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("hi")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_resource(
        "/work/unseen/.openseek",
      ),
    ),
    registered,
  )
  guard unseen.find_conversation(@interop.ChannelId::Local, "desktop-unseen")
    is Some(pending) else {
    fail("unregistered-store commit did not materialize its conversation")
  }
  assert_eq(
    pending.workspace,
    Project(root=@interop.ChannelId::Local.test_resource("/work/unseen")),
  )
}

///|
/// A same-id row from another store is a different durable record: it must
/// not suppress the list reload that gives the committed record its own row.
test "a commit for an unlisted store refreshes past a same-id row" {
  let dispatch = test_dispatch()
  let listed = @interop.ChannelId::Local.test_project()
  let other = @interop.ChannelId::Local.test_resource("/other")
  let store = @interop.ChannelId::Local.test_resource("/other/.openseek")
  let model = test_model().with_dev(dev => {
    ..dev,
    projects: [listed, other],
    sessions: [
      {
        id: "desktop-shared",
        title: Some("listed copy"),
        workspace: listed,
        workspace_name: "work",
        updated_at_ms: None,
      },
      {
        id: "desktop-listed-only",
        title: Some("listed chat"),
        workspace: listed,
        workspace_name: "work",
        updated_at_ms: None,
      },
    ],
  })
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-shared",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("hi")]),
        submission_id: None,
      }),
      session_root=store,
    ),
    model,
  )
  assert_eq(committed.dev().sessions_request_generation, 1)
  // The store that is already listed asks for nothing: this exact record has
  // its row, and the conversation is new to the page either way.
  let (_, same_store) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-listed-only",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("hi")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    committed,
  )
  assert_eq(same_store.dev().sessions_request_generation, 1)
}

///|
/// The unseen-commit gate has the same hazard as the listing check: the page
/// holds one conversation per (channel, id), so a record in one project that
/// already consumed sequence one must not make another project store's first
/// commit look like old news.
test "a commit for an unlisted store refreshes past a same-id watermark" {
  let dispatch = test_dispatch()
  let listed = @interop.ChannelId::Local.test_project()
  let other = @interop.ChannelId::Local.test_resource("/other")
  let store = @interop.ChannelId::Local.test_resource("/other/.openseek")
  let model = test_model().with_dev(dev => {
    ..dev,
    projects: [listed, other],
    sessions: [
      {
        id: "desktop-shared",
        title: Some("listed copy"),
        workspace: listed,
        workspace_name: "work",
        updated_at_ms: None,
      },
    ],
  })
  // The listed record consumes its own first commit, so the page now holds
  // that project's conversation at watermark one.
  let (_, first) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-shared",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("listed")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    model,
  )
  assert_eq(first.dev().sessions_request_generation, 0)
  guard first.find_conversation(@interop.ChannelId::Local, "desktop-shared")
    is Some(consumed) else {
    fail("listed commit did not materialize its conversation")
  }
  assert_eq(consumed.watermark, 1)
  // The other store's own first commit is a different durable record: it is
  // unlisted, and the listed watermark must not suppress its reload.
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session="desktop-shared",
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("other project")]),
        submission_id: None,
      }),
      session_root=store,
    ),
    first,
  )
  assert_eq(committed.dev().sessions_request_generation, 1)
}

///|
test "a background session list updates only its channel's same-id workspace" {
  let dispatch = test_dispatch()
  let remote : @interop.ChannelId = Remote("d-remote")
  let local_conv = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "shared",
      @interop.ChannelId::Local.test_project(),
    ),
    workspace: Project(root=@interop.ChannelId::Local.test_resource("/local")),
  }
  let remote_conv = {
    ..empty_conversation(remote, "shared", remote.test_project()),
    workspace: Project(root=remote.test_resource("/remote-old")),
  }
  let model = {
    ..test_model(),
    devices: [
      { ..empty_device_state(@interop.ChannelId::Local), bridge: Connected, },
      { ..empty_device_state(remote), bridge: Connected, },
    ],
    active_session: "shared",
    conversations: [local_conv, remote_conv],
  }
  let (_, next) = update(
    dispatch,
    FromDevice(
      remote,
      SessionsLoaded(
        [
          {
            id: "shared",
            title: Some("remote"),
            workspace: remote.test_resource("/remote-new"),
            workspace_name: "remote-new",
            updated_at_ms: None,
          },
        ],
        connection_generation=0,
        request_generation=0,
      ),
    ),
    model,
  )
  guard next.find_conversation(@interop.ChannelId::Local, "shared")
    is Some(local_conv) &&
    next.find_conversation(remote, "shared") is Some(remote_conv) else {
    fail("same-id conversations disappeared")
  }
  assert_true(
    local_conv.workspace is Project(root=workspace) &&
    workspace.path == "/local",
  )
  assert_true(
    remote_conv.workspace is Project(root=workspace) &&
    workspace.path == "/remote-new",
  )
}

///|
test "session list assigns a Started-first conversation to its durable workspace" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/started-first")
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="foreign-run",
      session="desktop-started-first",
      model=DsPro,
      max_steps=1000,
      session_root=Some(@interop.ChannelId::Local.test_store_root()),
      submission_id=None,
    ),
    test_model(),
  )
  guard started.find_conversation(
      @interop.ChannelId::Local,
      "desktop-started-first",
    )
    is Some(provisional) else {
    fail("Started did not materialize its conversation")
  }
  // The run's own store places it immediately; the listing that follows is
  // what moves it to the project the host groups it under.
  assert_eq(
    provisional.workspace,
    Project(root=@interop.ChannelId::Local.test_project()),
  )
  let (_, listed) = update(
    dispatch,
    sessions_loaded([
      {
        id: "desktop-started-first",
        title: Some("arrived before the list"),
        workspace,
        workspace_name: "started-first",
        updated_at_ms: None,
      },
    ]),
    started,
  )
  guard listed.find_conversation(
      @interop.ChannelId::Local,
      "desktop-started-first",
    )
    is Some(reconciled) else {
    fail("listed conversation disappeared")
  }
  assert_eq(reconciled.workspace, Project(root=workspace))
  assert_true(
    encoded_start_workspace(reconciled) is Some("/work/started-first"),
  )
}

///|
test "Started places a foreign conversation from its host session root" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/C:/work/core")
  let model = test_model().with_dev(dev => { ..dev, projects: [workspace], })
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="foreign-run",
      session="desktop-workspace-run",
      model=DsPro,
      max_steps=1000,
      session_root=Some(
        @interop.ChannelId::Local.test_resource("/C:/work/core/.openseek"),
      ),
      submission_id=None,
    ),
    model,
  )
  guard started.find_conversation(
      @interop.ChannelId::Local,
      "desktop-workspace-run",
    )
    is Some(foreign) else {
    fail("Started did not materialize its conversation")
  }
  assert_eq(foreign.workspace, Project(root=workspace))
  inspect(started.active_session, content="desktop-test")
}

///|
test "sessions failure pops a toast without touching the transcript" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation({
    ..test_conversation(),
    messages: [
      { kind: User(content=Content([Text("hi")])), ts: None, sequence: None, },
    ],
  })
  let (_, next) = update_dev(dispatch, SessionsFailed("engine exploded"), model)
  inspect(next.notifications.length(), content="1")
  inspect(
    next.notifications[0].message,
    content="Session list unavailable: engine exploded",
  )
  inspect(next.active().messages.length(), content="1")
}
