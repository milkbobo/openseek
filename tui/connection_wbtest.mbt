///|
fn epoch_settings(
  revision : Int32,
  provider : String,
) -> @protocol.SettingsStatusPayload {
  {
    revision,
    provider,
    custom_api_url: None,
    has_deepseek_key: true,
    has_glm_key: true,
    has_custom_key: false,
    followup_behavior: "steer",
  }
}

///|
test "a restarted server can begin approval and settings generations at zero" {
  let state = State(None)
  state.apply_settings(epoch_settings(20, "glm"))
  state.approval_generation = 40
  state.begin_connection()
  state.apply_settings(epoch_settings(0, "deepseek"))
  state.notification(AgentApprovals({ generation: 0, approvals: [], }))
  assert_eq(state.settings.map(settings => settings.revision), Some(0))
  assert_eq(state.settings.map(settings => settings.provider), Some("deepseek"))
  assert_eq(state.model, "deepseek-flash")
  assert_eq(state.approval_generation, 0)
}

///|
test "another client archives and restores the exact store without a writable stale selection" {
  let state = State(Some("/one"))
  let chat = state.active
  let session = chat.key.session
  let other = Chat({ session, workspace: Some("/two"), archived: false, })
  state.chats[other.key] = other
  chat.loading = true
  let generation = chat.snapshot_generation
  state.session_changed({ change: "archived", session, workspace: "/one", })
  assert_true(physical_equal(state.active, chat))
  assert_true(chat.key.archived)
  assert_true(!other.key.archived)
  assert_true(!chat.loading)
  assert_true(chat.snapshot_generation > generation)
  assert_true(
    !state.chats.contains({ session, workspace: Some("/one"), archived: false, }),
  )
  state.session_changed({ change: "unarchived", session, workspace: "/one", })
  assert_true(!chat.key.archived)
  assert_true(state.chats.contains(chat.key))
}

///|
test "another client's deletion removes cached history and replaces the selected record" {
  let state = State(Some("/one"))
  let chat = state.active
  let old = chat.key
  chat.notice("old transcript")
  state.session_changed({
    change: "deleted",
    session: old.session,
    workspace: "/one",
  })
  assert_true(!state.chats.contains(old))
  assert_true(!state.sidebar.contains(old))
  assert_true(state.active.key != old)
  assert_true(state.active.rows.is_empty())
}

///|
async test "reconnect reads a Codex turn completed offline before ordinary submission" {
  let completed : Json = {
    "id": "codex-offline",
    "name": "Offline completion",
    "status": { "type": "idle" },
    "turns": [
      {
        "id": "old-turn",
        "status": "completed",
        "items": [
          {
            "id": "answer",
            "type": "agentMessage",
            "text": "Finished while offline",
          },
        ],
      },
    ],
  }
  let state = State(None)
  guard state.codex.apply({
      "method": "thread/started",
      "params": {
        "thread": { "id": "codex-offline", "status": { "type": "idle" } },
      },
    })
    is Some(thread) else {
    fail("missing thread")
  }
  state.install_codex(thread, select=true)
  guard state.codex.apply({
      "method": "turn/started",
      "params": {
        "threadId": "codex-offline",
        "turn": { "id": "old-turn", "status": "inProgress" },
      },
    })
    is Some(running) else {
    fail("missing active turn")
  }
  state.install_codex(running)
  assert_eq(state.active.run_id, Some("old-turn"))
  state.begin_connection()
  with_terminal_peer(
    socket => {
      for
        method_ in [
          "session.list", "workspace.list", "agent.runs", "settings.get", "codex.thread.list",
          "codex.thread.list", "codex.thread.read", "codex.server_request.list",
          "codex.thread.resume", "codex.turn.start",
        ] {
        let (id, _) = terminal_request(socket, method_)
        let result : Json = match method_ {
          "session.list" => @protocol.SessionsReply::{ groups: [], }.to_json()
          "workspace.list" =>
            @protocol.WorkspacesReply::Workspaces([], chat_root=None).to_json()
          "agent.runs" =>
            @protocol.RunsReply::{
              approval_generation: 0,
              approvals: [],
              runs: [],
              settled: [],
            }.to_json()
          "settings.get" => epoch_settings(0, "deepseek").to_json()
          "codex.thread.list" => ({ "data": [], "nextCursor": null } : Json)
          "codex.thread.read" | "codex.thread.resume" =>
            @protocol.CodexCommandSuccess(@protocol.CodexThreadReply::{
              thread: completed,
            }).to_json()
          "codex.server_request.list" =>
            @protocol.CodexCommandSuccess(@protocol.CodexServerRequestsReply::{
              data: [],
              generation: 0,
            }).to_json()
          "codex.turn.start" =>
            @protocol.CodexCommandSuccess(@protocol.CodexTurnReply::{
              turn: Some({ "id": "new-turn", "status": "inProgress" }),
              turn_id: Some("new-turn"),
            }).to_json()
          _ => fail("unexpected command")
        }
        socket.send_text(
          ({ "jsonrpc": "2.0", "id": id, "result": result } : Json).stringify(),
        )
      }
    },
    client => {
      state.resync(client)
      assert_true(state.active.run_id is None)
      assert_eq(state.active.status, "completed")
      assert_true(
        state.active.rows.any(row => row.text == "Finished while offline"),
      )
      state.send_prompt(client, "next turn")
      assert_eq(state.active.run_id, Some("new-turn"))
    },
  )
}

///|
async test "startup in a registered workspace does not write the registry again" {
  with_terminal_peer(
    socket => {
      for
        method_ in [
          "session.list", "workspace.list", "agent.runs", "settings.get", "fs.browse",
          "workspace.settings_get", "worktree.list", "fs.read_directory", "fs.watch",
        ] {
        let (id, params) = terminal_request(socket, method_)
        let result : Json = match method_ {
          "session.list" => @protocol.SessionsReply::{ groups: [], }.to_json()
          "workspace.list" =>
            @protocol.WorkspacesReply::Workspaces(
              ["/workspace"],
              chat_root=None,
            ).to_json()
          "agent.runs" =>
            @protocol.RunsReply::{
              approval_generation: 0,
              approvals: [],
              runs: [],
              settled: [],
            }.to_json()
          "settings.get" => epoch_settings(0, "deepseek").to_json()
          "fs.browse" =>
            @protocol.BrowseDirectoryReply::Listing(
              path="/workspace",
              parent=Some("/"),
              entries=[],
            ).to_json()
          "workspace.settings_get" =>
            @protocol.WorkspaceSettingsPayload::{
              workspace: "/workspace",
              worktree_mode: false,
              checkout_submodules: false,
              submodule_checkout_timeout_seconds: 60,
            }.to_json()
          "worktree.list" =>
            @protocol.WorktreesReply::{ worktrees: [], }.to_json()
          "fs.read_directory" =>
            @protocol.ReadDirReply::{ entries: [], }.to_json()
          "fs.watch" => {
            let watch : @protocol.WatchWorkspacePayload = @json.from_json(
              params,
            )
            assert_eq(watch.recursive, Some(false))
            @protocol.EmptyReply::Acknowledged.to_json()
          }
          _ => fail("unexpected startup request")
        }
        selection_reply(socket, id, result)
      }
    },
    client => {
      let state = State(Some("/workspace"))
      state.resync(client)
      assert_eq(state.notice, "Connected")
      assert_true(!state.resync_needed)
    },
  )
}

///|
async test "Enter during startup is retained and runs once after loading" {
  with_terminal_peer(socket => ignore(socket.recv()), client => {
    @async.with_task_group(group => {
      let state = State(None)
      let events : @aqueue.Queue[Event] = Queue(kind=Blocking(8))
      state.busy = true
      state.loading_connection = true
      state.active.draft.set_text("/help")
      state.run_action(group, events, client, "/help")
      state.run_action(group, events, client, "/help")
      assert_true(state.startup_submission is Some(_))
      state.busy = false
      state.loading_connection = false
      guard state.take_startup_submission() is Some(text) else {
        fail("lost Enter")
      }
      state.run_action(group, events, client, text)
      assert_true(events.get() is Redraw)
      assert_true(state.panel_title is Some(_))
      assert_eq(state.active.draft.text(), "")
      assert_true(state.take_startup_submission() is None)
      state.active.draft.set_text("old")
      state.defer_startup_submission("old")
      state.active.draft.set_text("edited")
      assert_true(state.take_startup_submission() is None)
      assert_eq(state.active.draft.text(), "edited")
      state.defer_startup_submission("edited")
      state.new_chat(None)
      assert_true(state.take_startup_submission() is None)
      group.return_immediately(())
    })
  })
}
