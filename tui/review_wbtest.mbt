///|
test "CLI parses environment defaults and explicit options without swallowing flags" {
  let opts = options(["seekmoon-tui", "--engine", "explicit", "--snapshot"], env={
    "OPENSEEK_ENGINE": "environment",
    "SEEKMOON_SERVER_TOKEN": "secret",
  })
  assert_eq(opts.engine, "explicit")
  assert_eq(opts.token, Some("secret"))
  assert_true(opts.demo && opts.snapshot && !opts.help)
  assert_true(options(["seekmoon-tui", "-h"], env={}).help)
  try options(["seekmoon-tui", "--engine", "--snapshot"], env={}) catch {
    _ => ()
  } noraise {
    _ => fail("missing option value must be rejected")
  }
}

///|
test "upload filenames accept native Windows and POSIX paths" {
  assert_eq(upload_name("C:\\Users\\me\\image.png"), "image.png")
  assert_eq(upload_name("/Users/me/image.png"), "image.png")
  assert_eq(upload_name("image.png"), "image.png")
}

///|
test "Codex archive events migrate selected identity and preserve draft" {
  let state = State(Some("/project"))
  let thread = @codexchat.decode_thread({ "id": "t", "cwd": "/project" }).unwrap()
  state.install_codex(thread, select=true)
  let chat = state.active
  chat.draft.insert("unsent")
  let archived = state.codex
    .apply({
      "method": "thread/archived",
      "params": { "threadId": "t" },
      "generation": 0,
    })
    .unwrap()
  state.install_codex(archived)
  assert_true(physical_equal(state.active, chat))
  assert_true(state.active.key.archived)
  assert_eq(state.active.draft.text(), "unsent")
  assert_true(
    !state.chats.contains({
      session: "codex:t",
      workspace: Some("/project"),
      archived: false,
    }),
  )
  let restored = state.codex
    .apply({
      "method": "thread/unarchived",
      "params": { "threadId": "t" },
      "generation": 0,
    })
    .unwrap()
  state.install_codex(restored)
  assert_true(!state.active.key.archived)
  assert_eq(state.sidebar.filter(key => key.session == "codex:t").length(), 1)
}

///|
async test "successful startup selection is not replayed after reconnection" {
  with_terminal_peer(socket => ignore(socket.recv()), client => {
    let state = State(None)
    let opts = options(["tui"], env={})
    state.apply_startup(client, opts)
    state.begin_connection()
    // If reapplied this invalid page raises, replacing the user's navigation.
    state.apply_startup(client, { ..opts, page: Some("not-a-startup-page"), })
    assert_true(state.startup_applied)
  })
}

///|
async test "new Codex prompt places worktree before resuming and forwards reasoning effort" {
  with_terminal_peer(
    socket => {
      let (id, _) = terminal_request(socket, "workspace.settings_get")
      selection_reply(
        socket,
        id,
        @protocol.WorkspaceSettingsPayload::{
          workspace: "/project",
          worktree_mode: true,
          checkout_submodules: false,
          submodule_checkout_timeout_seconds: 60,
        }.to_json(),
      )
      let (id, params) = terminal_request(socket, "worktree.create")
      let payload : @protocol.WorktreeCreatePayload = @json.from_json(params)
      assert_eq(payload.session, None)
      assert_eq(payload.codex_thread, Some("t"))
      let tree : @protocol.WorktreeInfo = {
        name: "task",
        branch: Some("task"),
        base: "base",
        sessions: [],
        codex_thread: Some("t"),
        path: "/checkout",
        present: true,
      }
      selection_reply(
        socket,
        id,
        @protocol.WorktreeCreateResult::WorktreeCreatedReply({
          name: "task",
          worktrees: [tree],
        }).to_json(),
      )
      let (id, _) = terminal_request(socket, "worktree.list")
      selection_reply(
        socket,
        id,
        @protocol.WorktreesReply::{ worktrees: [tree], }.to_json(),
      )
      let (id, params) = terminal_request(socket, "fs.read_directory")
      assert_eq(params, ({ "path": "/checkout" } : Json))
      selection_reply(
        socket,
        id,
        @protocol.ReadDirReply::{ entries: [], }.to_json(),
      )
      let (id, _) = terminal_request(socket, "fs.watch")
      terminal_reply(socket, id)
      let (id, _) = terminal_request(socket, "codex.thread.resume")
      selection_reply(
        socket,
        id,
        @protocol.CodexCommandSuccess(@protocol.CodexThreadReply::{
          thread: {
            "id": "t",
            "cwd": "/project",
            "projectRoot": "/project",
            "openseekWorktree": { "path": "/checkout" },
          },
        }).to_json(),
      )
      let (id, params) = terminal_request(socket, "codex.turn.start")
      let payload : @protocol.CodexTurnStartPayload = @json.from_json(params)
      assert_eq(payload.cwd, Some("/checkout"))
      assert_eq(payload.effort, Some("high"))
      selection_reply(
        socket,
        id,
        @protocol.CodexCommandSuccess(@protocol.CodexTurnReply::{
          turn: None,
          turn_id: Some("turn"),
        }).to_json(),
      )
    },
    client => {
      let state = State(Some("/project"))
      state.install_codex(
        @codexchat.decode_thread({ "id": "t", "cwd": "/project" }).unwrap(),
        select=true,
      )
      state.active.codex_place_pending = true
      state.execute(client, "/thinking high")
      state.send_prompt(client, "hello")
      assert_true(!state.active.codex_place_pending)
      assert_eq(state.active.run_id, Some("turn"))
    },
  )
}

///|
async test "archived Codex catalog stays read only after thread refresh" {
  with_terminal_peer(
    socket => {
      let (id, _) = terminal_request(socket, "codex.thread.list")
      selection_reply(socket, id, {
        "data": [{ "id": "archived-thread", "cwd": "/project" }],
        "nextCursor": null,
      })
      let (id, _) = terminal_request(socket, "codex.thread.read")
      selection_reply(socket, id, {
        "thread": { "id": "archived-thread", "cwd": "/project", "turns": [] },
      })
      ignore(socket.recv())
    },
    client => {
      let state = State(Some("/project"))
      let listed = state.codex.list(client, archived=true)
      assert_true(listed[0].archived)
      state.install_codex(listed[0], select=true)
      state.install_codex(state.codex.read(client, "archived-thread"))
      assert_true(state.active.key.archived)
      try state.send_prompt(client, "must not send") catch {
        Failure(message) =>
          assert_true(
            message.contains("Unarchive this chat before sending a prompt"),
          )
        error => raise error
      } noraise {
        _ => fail("archived conversation accepted a prompt")
      }
    },
  )
}

///|
async test "failed Codex worktree placement retains draft and prevents submission" {
  with_terminal_peer(
    socket => {
      let (id, _) = terminal_request(socket, "workspace.settings_get")
      selection_reply(
        socket,
        id,
        @protocol.WorkspaceSettingsPayload::{
          workspace: "/project",
          worktree_mode: true,
          checkout_submodules: false,
          submodule_checkout_timeout_seconds: 60,
        }.to_json(),
      )
      let (id, _) = terminal_request(socket, "worktree.create")
      selection_reply(
        socket,
        id,
        @protocol.WorktreeCreateResult::WorktreeCreateError("checkout failed").to_json(),
      )
      ignore(socket.recv())
    },
    client => {
      let state = State(Some("/project"))
      state.install_codex(
        @codexchat.decode_thread({ "id": "t", "cwd": "/project" }).unwrap(),
        select=true,
      )
      state.active.codex_place_pending = true
      state.active.draft.insert("keep this")
      try state.send_prompt(client, "keep this") catch {
        Failure(message) => assert_true(message.contains("checkout failed"))
        error => raise error
      } noraise {
        _ => fail("submission ignored failed placement")
      }
      assert_eq(state.active.draft.text(), "keep this")
      assert_true(state.active.codex_place_pending)
    },
  )
}

///|
async test "archive notification wins over a stale live catalog page" {
  let state = State(None)
  with_terminal_peer(
    socket => {
      let (id, _) = terminal_request(socket, "codex.thread.list")
      ignore(
        state.codex.apply({
          "method": "thread/archived",
          "params": { "threadId": "t" },
          "generation": 0,
        }),
      )
      selection_reply(socket, id, {
        "data": [{ "id": "t" }],
        "nextCursor": null,
      })
    },
    client => {
      let threads = state.codex.list(client)
      assert_true(threads[0].archived)
    },
  )
}

///|
async test "reconnect recovers an archive performed while offline" {
  for unavailable in [false, true] {
    let state = State(None)
    let thread = state.codex
      .apply({
        "method": "turn/started",
        "params": {
          "threadId": "t",
          "turn": { "id": "old", "status": "inProgress", "items": [] },
        },
        "generation": 0,
      })
      .unwrap()
    state.install_codex(thread, select=true)
    state.begin_connection()
    with_terminal_peer(
      socket => {
        let methods = [
          "session.list", "workspace.list", "agent.runs", "settings.get", "codex.thread.list",
        ]
        if !unavailable {
          methods.push("codex.thread.list")
        }
        methods.append(["codex.thread.read", "codex.server_request.list"])
        for method_ in methods {
          let (id, params) = terminal_request(socket, method_)
          if unavailable && method_ == "codex.thread.list" {
            socket.send_text(
              (
                {
                  "jsonrpc": "2.0",
                  "id": id,
                  "error": { "code": -32000, "message": "Codex unavailable" },
                } : Json).stringify(),
            )
            continue
          }
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
            "codex.thread.list" => {
              let payload : @protocol.CodexThreadListPayload = @json.from_json(
                params,
              )
              if payload.archived {
                {
                  "data": [{ "id": "t" }, { "id": "untracked-archive" }],
                  "nextCursor": null,
                }
              } else {
                { "data": [], "nextCursor": null }
              }
            }
            "codex.thread.read" => { "thread": { "id": "t", "turns": [] } }
            "codex.server_request.list" => { "data": [], "generation": 0 }
            _ => fail("unexpected request")
          }
          selection_reply(socket, id, result)
        }
      },
      client => {
        state.resync(client)
        assert_true(state.codex.thread("untracked-archive") is None)
        assert_true(
          !state.chats
          .values()
          .any(chat => chat.codex_id() == Some("untracked-archive")),
        )
        assert_eq(state.active.key.archived, !unavailable)
        assert_eq(state.codex_catalog_error is Some(_), unavailable)
        assert_eq(state.notice, "Connected")
        assert_eq(state.active.run_id, None)
      },
    )
  }
}
