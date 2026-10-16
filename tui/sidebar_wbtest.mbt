///|
test "Projects sidebar groups original chat keys and keeps empty registered projects" {
  let state = State(Some("/projects/one"))
  let first = state.active.key
  state.new_chat(Some("/projects/two"))
  let second = state.active.key
  state.projects = ["/projects/one", "/projects/two", "/projects/empty"]
  state.sidebar_mode = ProjectsMode
  let rows = state.sidebar_rows()
  assert_eq(rows.length(), 6)
  assert_true(rows[0] is SidebarProject(Some("/projects/one"), 1, true))
  assert_true(rows[1] is SidebarChat(key) && key == first)
  assert_true(rows[2] is SidebarProject(Some("/projects/two"), 1, true))
  assert_true(rows[3] is SidebarChat(key) && key == second)
  assert_true(rows[4] is SidebarProject(Some("/projects/empty"), 0, true))
  assert_true(rows[5] is SidebarHint(_))
  state.collapsed_projects.add("/projects/one")
  assert_eq(state.sidebar_rows().length(), 5)
  assert_true(state.sidebar[0] == second)
  assert_true(state.sidebar[1] == first)
  assert_eq(state.sidebar_index, 0)
}

///|
test "new chat expands and reveals its containing project without changing its identity" {
  let state = State(Some("/projects/one"))
  state.projects = ["/projects/one", "/projects/two"]
  state.sidebar_mode = ProjectsMode
  state.collapsed_projects.add("/projects/two")
  state.new_chat(Some("/projects/two"))
  assert_true(!state.collapsed_projects.contains("/projects/two"))
  assert_true(
    state.sidebar_rows()[state.sidebar_cursor] is SidebarChat(key) &&
    key == state.active.key,
  )
  assert_eq(state.active.key.workspace, Some("/projects/two"))
  assert_eq(state.sidebar_index, 0)
}

///|
test "Projects navigation renders controls and accepts a pasted directory" {
  let state = State(Some("/projects/one"))
  state.projects = ["/projects/one", "/projects/empty"]
  state.sidebar_mode = ProjectsMode
  state.focus = Sidebar
  let frame = @tui.Frame(width=120, height=35)
  let regions = state.regions(@tui.Size(width=120, height=35))
  state.draw_sidebar(frame, regions)
  let text = frame.to_text()
  assert_true(text.contains("Projects"))
  assert_true(text.contains("one (1)"))
  assert_true(text.contains("empty (0)"))
  assert_true(!state.sidebar_paste("/projects/new"))
  state.project_entry = Some(@editor.Editor())
  assert_true(state.sidebar_paste("/projects/new 月"))
  guard state.project_entry is Some(editor) else {
    fail("Expected project entry")
  }
  assert_eq(editor.text(), "/projects/new 月")
}

///|
async test "Projects mouse selects the drawn row after the list shrinks and starts a project chat" {
  with_terminal_peer(
    socket => {
      let (id, params) = terminal_request(socket, "worktree.list")
      assert_eq(params, ({ "workspace": "/projects/one" } : Json))
      selection_reply(
        socket,
        id,
        @protocol.WorktreesReply::{ worktrees: [], }.to_json(),
      )
      let (id, params) = terminal_request(socket, "fs.read_directory")
      assert_eq(params, ({ "path": "/projects/one" } : Json))
      selection_reply(
        socket,
        id,
        @protocol.ReadDirReply::{ entries: [], }.to_json(),
      )
      let (id, params) = terminal_request(socket, "fs.watch")
      let watch : @protocol.WatchWorkspacePayload = @json.from_json(params)
      assert_eq(watch.path, "/projects/one")
      selection_reply(socket, id, @protocol.EmptyReply::Acknowledged.to_json())
    },
    client => {
      let state = State(Some("/projects/one"))
      state.sidebar_mode = ProjectsMode
      state.sidebar_cursor = 100
      let regions = state.regions(@tui.Size(width=120, height=35))
      ignore(
        state.sidebar_mouse(
          client,
          @input.MouseEvent::new(
            Press(Left),
            regions.left_chats.row + 1,
            regions.left_chats.col + 1,
          ),
          regions,
        ),
      )
      assert_true(state.collapsed_projects.contains("/projects/one"))
      let before = state.active.key
      ignore(
        state.sidebar_mouse(
          client,
          @input.MouseEvent::new(
            Press(Left),
            regions.left_chats.row + 1,
            regions.left_chats.col + regions.left_chats.width,
          ),
          regions,
        ),
      )
      assert_eq(state.active.key.workspace, Some("/projects/one"))
      assert_true(state.active.key != before)
      assert_true(!state.collapsed_projects.contains("/projects/one"))
    },
  )
}
