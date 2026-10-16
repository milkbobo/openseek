///|
fn explorer_text(state : State) -> String {
  let frame = @tui.Frame(width=50, height=12)
  state.workspace.draw_tree(frame, frame.area())
  frame.to_text()
}

///|
async fn selection_reply(
  socket : @websocket.Conn,
  id : Json,
  result : Json,
) -> Unit {
  socket.send_text(
    ({ "jsonrpc": "2.0", "id": id, "result": result } : Json).stringify(),
  )
}

///|
async test "new project selection clears the previous explorer even when checkout fails" {
  with_terminal_peer(
    socket => {
      let (id, params) = terminal_request(socket, "worktree.list")
      assert_eq(params, ({ "workspace": "/new project" } : Json))
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32000, "message": "checkout unavailable" },
          } : Json).stringify(),
      )
      let (id, _) = terminal_request(socket, "fs.unwatch")
      selection_reply(socket, id, @protocol.EmptyReply::Acknowledged.to_json())
    },
    client => {
      let state = State(Some("/old"))
      state.workspace.set_demo()
      assert_true(state.workspace.paste("unsaved draft "))
      assert_true(explorer_text(state).contains("main.mbt"))
      try state.execute(client, "/new '/new project'") catch {
        @client.ClientError::Rpc(..) => ()
        error => raise error
      } noraise {
        _ => fail("expected checkout failure")
      }
      assert_eq(state.active.key.workspace, Some("/new project"))
      assert_true(!explorer_text(state).contains("main.mbt"))
      assert_true(state.workspace.has_tabs())
      let editor = @tui.Frame(width=70, height=12)
      state.workspace.draw_editor(editor, editor.area())
      assert_true(editor.to_text().contains("unsaved draft"))
      state.start_chat(client, None)
      assert_eq(state.active.key.workspace, None)
      assert_true(!explorer_text(state).contains("main.mbt"))
    },
  )
}

///|
async test "local editor aliases share quoted path parsing and preserve the native editor" {
  with_terminal_peer(
    socket => {
      for command in ["/file", "/read", "/edit", "/diff"] {
        let (id, _) = terminal_request(socket, "worktree.list")
        selection_reply(
          socket,
          id,
          @protocol.WorktreesReply::{ worktrees: [], }.to_json(),
        )
        if command == "/diff" {
          let (id, _) = terminal_request(socket, "git.changes")
          selection_reply(
            socket,
            id,
            @protocol.GitChangesReply::{
              repository: true,
              head: Some("head"),
              baseline: Some("baseline"),
              changes: [],
            }.to_json(),
          )
        }
        let (id, params) = terminal_request(socket, "fs.read_file")
        let payload : @protocol.ReadFilePayload = @json.from_json(params)
        assert_eq(payload.path, "src/a file.mbt")
        assert_eq(payload.root, Some("/project"))
        selection_reply(
          socket,
          id,
          @protocol.ReadFileReply::Content(
            content="loaded text",
            absolute="/project/src/a file.mbt",
            sig="test",
          ).to_json(),
        )
        if command == "/diff" {
          let (id, _) = terminal_request(socket, "git.original_file")
          selection_reply(
            socket,
            id,
            @protocol.GitOriginalFileReply::OriginalContent("original text").to_json(),
          )
        }
      }
    },
    client => {
      let state = State(Some("/project"))
      for command in ["/file", "/read", "/edit", "/diff"] {
        state.execute(client, command + " 'src/a file.mbt'")
        assert_eq(state.workspace.title(), "/project/src/a file.mbt")
        assert_true(state.focus is Workspace)
        assert_true(state.editor_visible)
      }
      for invalid in ["'unfinished", "one two", "''"] {
        try file_argument(invalid) catch {
          @workbench.InputError(_) => ()
        } noraise {
          _ => fail("expected invalid path rejection")
        }
      }
    },
  )
}

///|
async test "new and opened Codex selections browse the raw thread checkout" {
  with_terminal_peer(
    socket => {
      for method_ in ["codex.thread.start", "codex.thread.read"] {
        let (id, _) = terminal_request(socket, method_)
        selection_reply(
          socket,
          id,
          @protocol.CodexThreadReply::{
            thread: {
              "id": "raw-thread",
              "projectRoot": "/project",
              "cwd": "/project",
            },
          }.to_json(),
        )
        let (id, params) = terminal_request(socket, "worktree.list")
        assert_eq(params, ({ "workspace": "/project" } : Json))
        selection_reply(
          socket,
          id,
          @protocol.WorktreesReply::{
            worktrees: [
              {
                name: "task",
                branch: None,
                base: "main",
                sessions: [],
                codex_thread: Some("raw-thread"),
                path: "/checkout",
                present: true,
              },
            ],
          }.to_json(),
        )
        let (id, params) = terminal_request(socket, "fs.read_directory")
        assert_eq(params, ({ "path": "/checkout" } : Json))
        selection_reply(
          socket,
          id,
          @protocol.ReadDirReply::{
            entries: [{ name: "correct.txt", is_dir: false, }],
          }.to_json(),
        )
        let (id, params) = terminal_request(socket, "fs.watch")
        let watch : @protocol.WatchWorkspacePayload = @json.from_json(params)
        assert_eq(watch.path, "/checkout")
        selection_reply(
          socket,
          id,
          @protocol.EmptyReply::Acknowledged.to_json(),
        )
      }
    },
    client => {
      let state = State(Some("/old"))
      state.workspace.set_demo()
      for command in ["new", "open raw-thread"] {
        state.codex_command(client, command)
        assert_eq(state.active.codex_id(), Some("raw-thread"))
        assert_true(explorer_text(state).contains("correct.txt"))
        assert_true(!explorer_text(state).contains("main.mbt"))
        assert_true(state.workspace.has_tabs())
      }
    },
  )
}
