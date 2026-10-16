///|
async fn with_workspace_client(
  body : async (@client.Client, Ref[String]) -> Unit,
  deleted~ : Bool = false,
) -> Unit {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let disk = Ref("\tfirst\r\nsecond\r\n")
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (connection, _) = server.accept()
        defer connection.close()
        let request = connection.read_request()
        let socket = @websocket.Conn::from_http_server(request, connection)
        defer socket.close()
        for ;; {
          let envelope = @json.parse(socket.recv().read_all().text())
          guard envelope is Object(fields) &&
            fields.get("id") is Some(id) &&
            fields.get("method") is Some(String(name)) else {
            fail("invalid workspace request")
          }
          let params = fields.get("params").unwrap_or(Json::empty_object())
          let result : Json = match name {
            "worktree.list" =>
              @protocol.WorktreesReply::{ worktrees: [], }.to_json()
            "fs.read_directory" =>
              @protocol.ReadDirReply::{
                entries: [{ name: "main.mbt", is_dir: false, }],
              }.to_json()
            "fs.read_file" => {
              assert_true(!deleted)
              @protocol.ReadFileReply::Content(
                content=disk.val,
                absolute="/workspace/main.mbt",
                sig="test",
              ).to_json()
            }
            "git.changes" =>
              @protocol.GitChangesReply::{
                repository: true,
                head: Some("new-head"),
                baseline: Some("task-base"),
                changes: [
                  {
                    path: "main.mbt",
                    original_path: Some("before.mbt"),
                    index_status: "R",
                    worktree_status: " ",
                    kind: if deleted {
                      "deleted"
                    } else {
                      "renamed"
                    },
                  },
                ],
              }.to_json()
            "git.original_file" => {
              let payload : @protocol.GitOriginalFilePayload = @json.from_json(
                params,
              )
              assert_eq(payload.revision, Some("task-base"))
              assert_eq(payload.path, "before.mbt")
              @protocol.GitOriginalFileReply::OriginalContent("old\n").to_json()
            }
            "fs.watch" => {
              let payload : @protocol.WatchWorkspacePayload = @json.from_json(
                params,
              )
              assert_eq(payload.path, "/workspace")
              assert_eq(payload.recursive, Some(true))
              @protocol.EmptyReply::Acknowledged.to_json()
            }
            "fs.write_file" => {
              let payload : @protocol.WriteFilePayload = @json.from_json(params)
              assert_eq(payload.root, None)
              assert_eq(payload.path, "/workspace/main.mbt")
              if payload.expected_content != Some(disk.val) {
                socket.send_text(
                  (
                    {
                      "jsonrpc": "2.0",
                      "id": id,
                      "error": {
                        "code": -32000,
                        "message": "file changed on disk",
                      },
                    } : Json).stringify(),
                )
                continue
              }
              disk.val = payload.content
              @protocol.WriteFileReply::{ path: payload.path, }.to_json()
            }
            _ => fail("unexpected workspace command " + name)
          }
          socket.send_text(
            ({ "jsonrpc": "2.0", "id": id, "result": result } : Json).stringify(),
          )
        }
      })
      let client = @client.Client::connect(
        "ws://127.0.0.1:\{server.addr.port()}/v1/devices/host/ws",
        token="test",
      )
      defer client.close()
      group.spawn_bg(allow_failure=true, () => client.run())
      body(client, disk)
      group.return_immediately(())
    })
  })
}

///|
fn fixture_context() -> @workbench.Context {
  {
    codex_thread: None,
    session: "chat",
    workspace: Some("/workspace"),
    model: "deepseek-flash",
    run_id: None,
    archived: false,
  }
}

///|
fn changed(state : State, generation~ : String = "") -> @protocol.Notification {
  @protocol.Notification::FsChanged({
    root: "/workspace",
    baseline: true,
    events: [],
    generation: if generation.is_empty() {
      state.watch_generation.unwrap_or("missing")
    } else {
      generation
    },
  })
}

///|
async test "remote editor preserves source and rejects conflicting disk writes" {
  with_workspace_client((client, disk) => {
    let state = State()
    state.browse(client, fixture_context())
    state.open(client, fixture_context(), "main.mbt")
    let source = disk.val
    assert_eq(state.tabs[0].editor.text(), source)
    assert_true(state.paste("new\tline\r\n"))
    state.save(client)
    assert_eq(disk.val, "new\tline\r\n" + source)
    assert_true(!state.tabs[0].dirty())
    assert_true(state.paste("draft"))
    disk.val = "another client wrote this\n"
    try state.save(client) catch {
      @client.ClientError::Rpc(..) => ()
      error => raise error
    } noraise {
      _ => fail("a stale editor baseline overwrote another client's change")
    }
    assert_true(state.tabs[0].dirty())
    assert_true(state.tabs[0].editor.text().contains("draft"))
    assert_eq(disk.val, "another client wrote this\n")
  })
}

///|
async test "watch baselines refresh clean editors and preserve dirty drafts" {
  with_workspace_client((client, disk) => {
    let state = State()
    state.browse(client, fixture_context())
    state.open(client, fixture_context(), "main.mbt")
    disk.val = "agent update 🌙\n"
    state.notification(client, changed(state, generation="old-connection"))
    assert_true(state.tabs[0].editor.text() != disk.val)
    state.notification(client, changed(state))
    assert_eq(state.tabs[0].editor.text(), disk.val)
    assert_true(!state.tabs[0].dirty())
    assert_true(state.paste("my draft "))
    let draft = state.tabs[0].editor.text()
    disk.val = "agent update two\n"
    state.notification(client, changed(state))
    assert_eq(state.tabs[0].editor.text(), draft)
    assert_true(state.tabs[0].external_changed)
    assert_true(state.tabs[0].dirty())
  })
}

///|
async test "unified diff input is readonly and edits remain available in working view" {
  with_workspace_client((client, _) => {
    let state = State()
    state.open(client, fixture_context(), "main.mbt", diff=true)
    let tab = state.tabs[0]
    tab.unified = true
    let before = tab.editor.text()
    assert_true(state.paste("should not enter source"))
    assert_true(state.key(client, @input.KeyEvent::new(Char('x'), text="x")))
    assert_eq(tab.editor.text(), before)
    assert_true(
      state.key(
        client,
        @input.KeyEvent::new(
          Char('d'),
          modifiers=@input.KeyModifiers::new(ctrl=true),
        ),
      ),
    )
    assert_true(!tab.unified)
    assert_true(state.paste("edited "))
    assert_eq(tab.editor.text(), "edited " + before)
  })
}

///|
test "offline workspace fixture draws the code diff and explorer" {
  let state = State()
  state.set_demo(diff=true)
  let frame = @tui.Frame(width=120, height=25)
  state.draw_editor(
    frame,
    @tui.Rect(row=0, col=0, width=90, height=25),
    focused=true,
  )
  state.draw_tree(frame, @tui.Rect(row=0, col=90, width=30, height=25))
  assert_true(frame.to_text().contains("Working tree"))
  assert_true(frame.to_text().contains("greeting"))
  assert_true(frame.to_text().contains("main.mbt"))
}

///|
async test "deleted files open against the task baseline without reading missing disk content" {
  with_workspace_client(
    (client, _) => {
      let state = State()
      state.open(client, fixture_context(), "main.mbt", diff=true)
      assert_eq(state.tabs[0].original.text(), "old\n")
      assert_eq(state.tabs[0].editor.text(), "")
      assert_eq(state.tabs[0].baseline, None)
    },
    deleted=true,
  )
}

///|
async test "explorer wheel stays scrolled after draw and keyboard reveals selection" {
  with_workspace_client((client, _) => {
    let state = State()
    state.tree = Array::makei(30, index => {
      path: "/workspace/\{index}",
      name: "file\{index}",
      depth: 0,
      is_dir: false,
    })
    let frame = @tui.Frame(width=30, height=8)
    state.draw_tree(frame, frame.area())
    ignore(
      state.mouse(
        client,
        @input.MouseEvent::new(Scroll(Down), 3, 3),
        fixture_context(),
      ),
    )
    state.draw_tree(frame, frame.area())
    assert_eq(state.top, 3)
    assert_true(!frame.to_text().contains("file0"))
    ignore(state.key(client, @input.KeyEvent::new(Home)))
    state.draw_tree(frame, frame.area())
    assert_eq(state.top, 0)
  })
}
