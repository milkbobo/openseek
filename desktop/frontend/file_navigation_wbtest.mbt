///|
test "a file-link host failure is visible only for the latest navigation" {
  let dispatch = test_dispatch()
  let model = test_model()
  let owner : @interop.ConversationKey = {
    channel: model.focused,
    session: model.active().session_id,
  }
  let newer = model.begin_editor_navigation()
  let (_, stale) = update(
    dispatch,
    OpenPathResolved(FileOpenContext::new(owner, 0), Refused("old path failed")),
    newer,
  )
  inspect(stale.notifications.length(), content="0")
  let (_, current) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, 1),
      Refused("current path failed"),
    ),
    newer,
  )
  inspect(current.notifications.length(), content="1")
  inspect(current.notifications[0].message, content="current path failed")
}

///|
test "a Codex file-link failure is fenced by the selected Codex task" {
  let dispatch = test_dispatch()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-1",
      "preview": "Open a file",
      "cwd": "/work/codex-project",
      "turns": [],
    },
  })
  let model = { ..test_model(), codex, screen: Codex, }.begin_editor_navigation()
  let hidden_openseek : @interop.ConversationKey = {
    channel: model.focused,
    session: model.active().session_id,
  }
  let codex_owner : @interop.ConversationKey = {
    channel: model.focused,
    session: "codex-thread-1",
  }
  let (_, hidden) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(hidden_openseek, 1),
      Refused("hidden OpenSeek failure"),
    ),
    model,
  )
  inspect(hidden.notifications.length(), content="0")
  let message = OpenPathResolved(
    FileOpenContext::new(codex_owner, 1),
    Refused("Codex path failed"),
  )
  let (_, first) = update(dispatch, message, model)
  let (_, second) = update(dispatch, message, model)
  inspect(first.notifications.length(), content="1")
  inspect(first.notifications[0].message, content="Codex path failed")
  assert_true(first.notifications == second.notifications)
  assert_eq(first.notification_seq, second.notification_seq)
}

///|
test "a mention chip opens the editor panel and selects the mention's file" {
  let dispatch = test_dispatch()
  let mention : Mention = {
    ref_: Symbol(name="parse_hover", file="src/main.mbt", line=5),
    range: Some(@common.Range(5, 1, 5, 12)),
  }
  let model = test_model()
  let (_, next) = update(dispatch, mention_opened(mention), model)
  assert_false(next.right_panel_open)
  assert_true(next.dock.tabs.is_empty())
  let next = next.test_resolve_editor("src/main.mbt")
  assert_true(next.right_panel_open)
  assert_true(next.active_workspace_file() is Some(Relative("src/main.mbt")))
  assert_eq(next.file_panel.file_link_generation, 1)
  // The document table follows the strip: the jumped-to file has an entry.
  assert_true(next.file_panel.docs.contains(model.test_file("src/main.mbt")))
  let resource = model.test_file("pkg.generated.mbti")
  let path = resource.path
  for
    (range, annotation) in [
      (Some(@common.Range(5, 2, 8, 12)), None),
      (None, Some("review note")),
    ] {
    let modes = Map([(resource, @fileeditor.MbtiDiagram)])
    let base = {
      ..next,
      file_panel: { ..next.file_panel, mbti_view_modes: modes, },
    }
    let (_, pending) = update(
      dispatch,
      JumpToLocation(path~, range~, annotation~),
      base,
    )
    let response = OpenPathResolved(
      FileOpenContext::new(
        file_ctx(pending).owner,
        pending.file_panel.file_link_generation,
        range?,
        annotation?,
      ),
      Editor({ path, line: None, column: None, }),
    )
    let (_, opened) = update(dispatch, response, pending)
    assert_true(
      opened.file_panel.mbti_view_modes.get(resource) is Some(MbtiSource),
    )
  }
}

///|
test "resolved transcript files and directories stay in the right panel" {
  let dispatch = test_dispatch()
  let model = test_model()
  let owner : @interop.ConversationKey = {
    channel: Local,
    session: "desktop-test",
  }
  let (_, file_pending) = update(dispatch, OpenFile("src/main.mbt"), model)
  let (_, file) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, 1),
      Editor({ path: "src/main.mbt", line: None, column: None, }),
    ),
    file_pending,
  )
  assert_true(file.right_panel_open)
  assert_true(file.active_workspace_file() is Some(Relative("src/main.mbt")))

  let (_, directory_pending) = update(dispatch, OpenFile("src"), model)
  let directory_msg = OpenPathResolved(
    FileOpenContext::new(owner, 1),
    Directory({ path: "src", }),
  )
  let (_, directory) = update(dispatch, directory_msg, directory_pending)
  assert_true(directory.right_panel_open)
  assert_true(directory.dock.active is Some(FilePicker))
  assert_true(directory.file_panel.tree_open)
  assert_true(directory.file_panel.highlighted is Some(Relative("src")))
  assert_true(directory.file_panel.expanded.contains(Relative("src")))
  // Repeating the same link is a reveal, not the row's collapse toggle.
  let (_, repeated) = update(dispatch, directory_msg, directory)
  assert_true(repeated.file_panel.expanded.contains(Relative("src")))
  let desktop = { ..model, is_desktop: true, }
  let (_, pending) = update(dispatch, OpenFile("report.pdf"), desktop)
  let browser_msg = OpenPathResolved(
    FileOpenContext::new(owner, 1),
    Browser("/work/project/report.pdf"),
  )
  let (_, browser) = update(dispatch, browser_msg, pending)
  assert_true(browser.right_panel_open)
  assert_true(@dock.active_browser(browser.dock) is Some(_))
  assert_eq(browser.preview.pages.length(), 1)
  let (_, reused) = update(dispatch, browser_msg, browser)
  assert_eq(reused.preview.pages.length(), 1)
  let (_, stale) = update(
    dispatch,
    OpenPathResolved(FileOpenContext::new(owner, 0), Browser("/tmp/stale.pdf")),
    reused,
  )
  assert_eq(stale.preview.pages.length(), 1)
  let (_, remote_console) = update(dispatch, browser_msg, {
    ..pending,
    is_desktop: false,
  })
  assert_eq(remote_console.preview.pages.length(), 0)
  let (_, other_owner) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new({ channel: Local, session: "other", }, 1),
      Browser("/tmp/other.pdf"),
    ),
    pending,
  )
  assert_eq(other_owner.preview.pages.length(), 0)
  // Tree picks are classified even without a PDF suffix, and fulfill the picker.
  let (_, picker) = update(dispatch, ExplorerRequested(ExplorerFiles), desktop)
  for name in ["report", "report.pdf", "report.txt"] {
    let pick = FileEditor(FileSelected(path=Relative(name), name~))
    let (_, pending) = update(dispatch, pick, picker)
    let (_, repeated) = update(dispatch, pick, picker)
    assert_eq(
      pending.file_panel.file_link_generation,
      repeated.file_panel.file_link_generation,
    )
    assert_true(pending.dock == picker.dock)
    let response = OpenPathResolved(
      FileOpenContext::new(owner, pending.file_panel.file_link_generation),
      Browser("/work/project/" + name),
    )
    let (_, opened) = update(dispatch, response, pending)
    let (_, replayed) = update(dispatch, response, pending)
    assert_true(opened.dock == replayed.dock)
    assert_false(opened.dock.tabs.contains(@dock.DockTab::FilePicker))
    assert_eq(opened.dock.tabs.length(), 1)
    assert_true(@dock.active_browser(opened.dock) is Some(_))
  }
  // A mention from another conversation parks its result under that owner.
  let target_owner : @interop.ConversationKey = {
    channel: Local,
    session: "background",
  }
  let background = desktop.replace_conversation({
    ..test_conversation(),
    session_id: target_owner.session,
  })
  let mention_msg = ComposerAction(
    @composer.MentionOpened(
      identity={ owner: target_owner, archive_generation: 0, },
      mention={ ref_: File(path="report"), range: None, },
    ),
  )
  let (_, pending) = update(dispatch, mention_msg, background)
  assert_eq(pending.active_session, background.active_session)
  assert_eq(
    pending.file_panel.file_link_generation,
    background.file_panel.file_link_generation + 1,
  )
  let response = OpenPathResolved(
    FileOpenContext::new(
      target_owner,
      pending.file_panel.file_link_generation,
      return_to=owner,
    ),
    Browser("/work/project/report"),
  )
  let (_, parked) = update(dispatch, response, pending)
  let (_, replayed) = update(dispatch, response, pending)
  assert_eq(parked.active_session, background.active_session)
  assert_true(parked.dock == replayed.dock)
  assert_eq(parked.dock.owner, Some(owner))
  assert_true(parked.dock.active is None)
  assert_true(
    parked.dock.remembered.get(target_owner)
    is Some({ active: Some(Browser(..)), .. }),
  )
  let (_, obsolete) = update(
    dispatch,
    response,
    pending.begin_editor_navigation(),
  )
  assert_eq(obsolete.preview.pages.length(), 0)
}

///|
test "update is pure: a resolved transcript position opens its owning file" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/project")
  let worktree = @interop.ChannelId::Local.test_resource(
    "/work/project/.worktrees/wt-4",
  )
  let main_file = @resource.join_relative(worktree, Relative("src/main.mbt"))
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Worktree(project=workspace, name="wt-4"),
    })
    .with_dev(dev => {
      ..dev,
      projects: [workspace],
      worktrees: [
        {
          project: workspace,
          rows: [
            {
              name: "wt-4",
              session: Some("desktop-test"),
              codex_thread: None,
              path: Some(worktree),
              present: true,
            },
          ],
          generation: 1,
        },
      ],
    })
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "desktop-test",
  }
  // Spending the generation is part of the pure click transition, before the
  // host command runs. Replaying the same input therefore produces the same
  // token rather than consulting hidden state.
  let (_, first_pending) = update(dispatch, OpenFile("src/main.mbt:1"), model)
  let (_, replayed_pending) = update(
    dispatch,
    OpenFile("src/main.mbt:1"),
    model,
  )
  assert_eq(first_pending.file_panel.file_link_generation, 1)
  assert_eq(replayed_pending.file_panel.file_link_generation, 1)
  let (_, latest_pending) = update(
    dispatch,
    OpenFile("src/main.mbt:2738:17"),
    first_pending,
  )
  assert_eq(latest_pending.file_panel.file_link_generation, 2)
  // Routing is asynchronous: a path that later goes to the system must not
  // open an empty panel while the host is still classifying it.
  assert_false(latest_pending.right_panel_open)
  // The panel may already be showing another document while this host lookup
  // is pending. Closing that open panel is a newer user decision; its delayed
  // reply cannot reopen the panel.
  let panel_open_pending = { ..latest_pending, right_panel_open: true, }
  let (_, panel_closed) = update(dispatch, ToggleRightPanel, panel_open_pending)
  assert_false(panel_closed.right_panel_open)
  assert_eq(panel_closed.file_panel.file_link_generation, 3)
  let (_, after_closed_reply) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, 2),
      Editor({ path: "src/main.mbt", line: Some(2738), column: Some(17), }),
    ),
    panel_closed,
  )
  assert_false(after_closed_reply.right_panel_open)
  assert_true(after_closed_reply.dock.active is None)
  // Revealing an existing tab is also a newer dock navigation. The pending
  // reply cannot replace the file the user chose to bring back on screen.
  let hidden_pending = {
    ..latest_pending,
    dock: @dock.open_file(latest_pending.dock, model.test_file("README.md")),
    right_panel_open: false,
  }
  let (_, panel_opened) = update(dispatch, ToggleRightPanel, hidden_pending)
  assert_true(panel_opened.right_panel_open)
  assert_eq(panel_opened.file_panel.file_link_generation, 3)
  assert_true(
    panel_opened.active_workspace_file() is Some(Relative("README.md")),
  )
  let (_, after_opened_reply) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, 2),
      Editor({ path: "src/main.mbt", line: Some(2738), column: Some(17), }),
    ),
    panel_opened,
  )
  assert_true(
    after_opened_reply.active_workspace_file() is Some(Relative("README.md")),
  )
  assert_false(
    after_opened_reply.dock.tabs.contains(@dock.DockTab::File(path=main_file)),
  )
  // The first host reply is stale as soon as the second click happens.
  let (_, old_host_reply) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, 1),
      Editor({ path: "src/main.mbt", line: Some(1), column: None, }),
    ),
    latest_pending,
  )
  assert_true(old_host_reply.dock.active is None)
  let msg = OpenPathResolved(
    FileOpenContext::new(owner, 2),
    Editor({ path: "src/main.mbt", line: Some(2738), column: Some(17), }),
  )
  let (_, first) = update(dispatch, msg, latest_pending)
  let (_, second) = update(dispatch, msg, latest_pending)
  assert_true(first.active_workspace_file() is Some(Relative("src/main.mbt")))
  assert_true(first.right_panel_open)
  assert_true(second.active_workspace_file() is Some(Relative("src/main.mbt")))
  assert_true(first.file_panel.docs.contains(main_file))
  assert_true(second.file_panel.docs.contains(main_file))
  // A later ordinary navigation of the same loading file owns its read with
  // the same generation token. If that newer read fails first, the older
  // positioned success cannot fill the failed tab afterward.
  let (_, ordinary_pending) = update(
    dispatch,
    FileEditor(
      @fileeditor.OpenNavigationLocation(
        owner~,
        path=Relative("src/main.mbt"),
        range=@common.Range(9, 1, 9, 4),
      ),
    ),
    first,
  )
  let ordinary_pending = ordinary_pending.test_resolve_editor("src/main.mbt")
  assert_eq(ordinary_pending.file_panel.file_link_generation, 3)
  let (_, ordinary_failed) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileFailed(
        owner~,
        epoch=ordinary_pending.file_panel.request_epoch,
        path=main_file,
        file_link_generation=Some(3),
        review_generation=None,
        message="newer ordinary read failed",
      ),
    ),
    ordinary_pending,
  )
  assert_true(
    ordinary_failed.file_panel.docs.get(main_file)
    is Some(
      { state: @fileeditor.TabReadFailed("newer ordinary read failed"), .. }
    ),
  )
  let (_, old_after_failure) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileLoaded(
        owner~,
        epoch=ordinary_failed.file_panel.request_epoch,
        path=main_file,
        name="main.mbt",
        file=@fileeditor.Content(content="old", sig="1:3"),
        file_link_generation=Some(2),
        review_generation=None,
        range=Some(@common.Range(2738, 17, 2738, 17)),
        annotation=None,
      ),
    ),
    ordinary_failed,
  )
  assert_true(old_after_failure == ordinary_failed)
  // Both host replies can arrive in click order while the corresponding file
  // reads settle in reverse. The older read may finish the loading document,
  // but it cannot move the Viewer back to its stale position.
  let (_, old_file_reply) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileLoaded(
        owner~,
        epoch=first.file_panel.request_epoch,
        path=main_file,
        name="main.mbt",
        file=@fileeditor.Content(content="old", sig="1:3"),
        file_link_generation=Some(1),
        review_generation=None,
        range=Some(@common.Range(1, 1, 1, 1)),
        annotation=None,
      ),
    ),
    first,
  )
  assert_true(
    old_file_reply.file_panel.docs.get(main_file)
    is Some({ state: @fileeditor.TabLoaded(content="old", ..), .. }),
  )
  // A stale failure likewise makes its loading tab retryable without raising
  // a panel-wide error or applying the old position.
  let (_, old_file_failure) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileFailed(
        owner~,
        epoch=first.file_panel.request_epoch,
        path=main_file,
        file_link_generation=Some(1),
        review_generation=None,
        message="old read failed",
      ),
    ),
    first,
  )
  assert_true(old_file_failure.file_panel.error is None)
  assert_true(
    old_file_failure.file_panel.docs.get(main_file)
    is Some({ state: @fileeditor.TabReadFailed("old read failed"), .. }),
  )
  // The current failure is authoritative even if the stale success filled the
  // cache first, so the superseded snapshot cannot survive the failed read.
  let (_, current_file_failure) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileFailed(
        owner~,
        epoch=first.file_panel.request_epoch,
        path=main_file,
        file_link_generation=Some(2),
        review_generation=None,
        message="current read failed",
      ),
    ),
    old_file_reply,
  )
  assert_true(current_file_failure.file_panel.error is None)
  assert_true(
    current_file_failure.file_panel.docs.get(main_file)
    is Some({ state: @fileeditor.TabReadFailed("current read failed"), .. }),
  )
  let (_, current_file_reply) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileLoaded(
        owner~,
        epoch=first.file_panel.request_epoch,
        path=main_file,
        name="main.mbt",
        file=@fileeditor.Content(content="new", sig="2:3"),
        file_link_generation=Some(2),
        review_generation=None,
        range=Some(@common.Range(2738, 17, 2738, 17)),
        annotation=None,
      ),
    ),
    old_file_reply,
  )
  assert_true(
    current_file_reply.file_panel.docs.get(main_file)
    is Some({ state: @fileeditor.TabLoaded(content="new", ..), .. }),
  )
  // Closing an inactive file tab is also newer than a pending positioned
  // link to that file. Its delayed host reply must not recreate the tab.
  let (_, other_file) = update(
    dispatch,
    FileEditor(FileSelected(path=Relative("README.md"), name="README.md")),
    current_file_reply,
  )
  let other_file = other_file.test_resolve_editor("README.md")
  assert_true(other_file.active_workspace_file() is Some(Relative("README.md")))
  let (_, inactive_pending) = update(
    dispatch,
    OpenFile("src/main.mbt:40"),
    other_file,
  )
  let pending_generation = inactive_pending.file_panel.file_link_generation
  let (_, inactive_closed) = update(
    dispatch,
    Dock(TabClosed(@dock.DockTab::File(path=main_file))),
    inactive_pending,
  )
  assert_eq(
    inactive_closed.file_panel.file_link_generation,
    pending_generation + 1,
  )
  assert_false(
    inactive_closed.dock.tabs.contains(@dock.DockTab::File(path=main_file)),
  )
  let (_, after_inactive_reply) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, pending_generation),
      Editor({ path: "src/main.mbt", line: Some(40), column: None, }),
    ),
    inactive_closed,
  )
  assert_false(
    after_inactive_reply.dock.tabs.contains(@dock.DockTab::File(path=main_file)),
  )
  // A later tree pick competes with the transcript request just like a newer
  // transcript click: it advances the same token before opening its document.
  let (_, tree_opened) = update(
    dispatch,
    FileEditor(FileSelected(path=Relative("README.md"), name="README.md")),
    latest_pending,
  )
  let tree_opened = tree_opened.test_resolve_editor("README.md")
  assert_eq(tree_opened.file_panel.file_link_generation, 3)
  let (_, delayed_transcript_reply) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new(owner, 2),
      Editor({ path: "src/main.mbt", line: Some(2738), column: Some(17), }),
    ),
    tree_opened,
  )
  assert_true(
    delayed_transcript_reply.active_workspace_file()
    is Some(Relative("README.md")),
  )
  assert_false(delayed_transcript_reply.file_panel.docs.contains(main_file))
  // A delayed reply from another conversation cannot open a tab here.
  let (_, stale) = update(
    dispatch,
    OpenPathResolved(
      FileOpenContext::new({ ..owner, session: "another-session", }, 2),
      Editor({
        path: "/work/project/src/main.mbt",
        line: Some(1),
        column: None,
      }),
    ),
    latest_pending,
  )
  assert_true(stale.dock.active is None)
  assert_false(stale.file_panel.docs.contains(main_file))
}

///|
test "a mention chip without a resolved location is a no-op" {
  let dispatch = test_dispatch()
  let mention : Mention = { ref_: Skill(name="review-pr"), range: None, }
  let (_, next) = update(dispatch, mention_opened(mention), test_model())
  assert_false(next.right_panel_open)
  assert_true(next.dock.active is None)
}

///|
test "chip jumps relativize legacy absolute paths against the roots" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/project")
  // A project conversation uses its project root.
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Project(root=workspace),
    })
    .with_dev(dev => {
      ..dev,
      worktrees: [{ project: workspace, rows: [], generation: 1, }],
    })
  let model = {
    ..model,
    file_panel: {
      ..model.file_panel,
      owner: Some({
        channel: @interop.ChannelId::Remote("previous"),
        session: "previous-session",
      }),
      tree_open: false,
      explorer_mode: @fileeditor.ExplorerChanges,
      changes_generation: 7,
      watch_generation: 11,
    },
  }
  let (_, next) = update(
    dispatch,
    JumpToLocation(
      path="/work/project/src/main.mbt",
      range=Some(@common.Range(5, 1, 5, 1)),
      annotation=None,
    ),
    model,
  )
  let next = next.test_resolve_editor("/work/project/src/main.mbt")
  assert_true(next.active_workspace_file() is Some(Relative("src/main.mbt")))
  assert_false(next.file_panel.tree_open)
  assert_true(next.file_panel.explorer_mode is @fileeditor.ExplorerChanges)
  // The eager re-root retains 7. The jump keeps the explorer hidden while the
  // file is active, so Changes waits until the pane is shown before refreshing.
  assert_true(next.file_panel.changes_generation == 7)
  // The fresh watch spends the next page-lifetime identity; resetting the
  // eager panel to zero would let an older generation 1 push collide here.
  assert_eq(next.file_panel.watch_generation, 12)
  // The registry can still be loading; once loaded, the project root remains
  // the conversation root when no worktree row binds this session.
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Project(root=workspace),
    })
    .with_dev(dev => {
      ..dev,
      worktrees: [{ project: workspace, rows: [], generation: 1, }],
    })
  let (_, next) = update(
    dispatch,
    JumpToLocation(
      path="/work/project/src/main.mbt",
      range=Some(@common.Range(5, 1, 5, 1)),
      annotation=None,
    ),
    model,
  )
  let next = next.test_resolve_editor("/work/project/src/main.mbt")
  assert_true(next.active_workspace_file() is Some(Relative("src/main.mbt")))
  // Outside files share the same dock and document table, with no workspace
  // membership and no error.
  let (_, outside) = update(
    dispatch,
    JumpToLocation(
      path="/elsewhere/note.md",
      range=Some(@common.Range(1, 1, 1, 1)),
      annotation=None,
    ),
    model,
  )
  let outside = outside.test_resolve_editor("/elsewhere/note.md")
  let external = @interop.ChannelId::Local.test_resource("/elsewhere/note.md")
  assert_true(@dock.active_file(outside.dock) == Some(external))
  assert_true(outside.file_panel.docs.contains(external))
  assert_true(outside.active_workspace_file() is None)
  assert_true(outside.file_panel.error is None)
}

///|
test "RevealDirectory(\"\") opens the workspace breadcrumb picker" {
  let dispatch = test_dispatch()
  let model = test_model()
  let owner : @interop.ConversationKey = {
    channel: Local,
    session: "desktop-test",
  }
  let dock = {
    ..@dock.open_file(model.dock, model.test_file("README.md")),
    owner: Some(owner),
  }
  let panel = {
    ..model.file_panel,
    owner: Some(owner),
    tree_open: false,
    highlighted: Some(Relative("src")),
  }
  let (_, next) = update(
    dispatch,
    FileEditor(RevealDirectory(@pathx.Relative::root())),
    { ..model, dock, file_panel: panel, right_panel_open: true, },
  )
  // The active tab and docked explorer stay put while the picker opens.
  assert_true(next.active_workspace_file() is Some(Relative("README.md")))
  assert_false(next.file_panel.tree_open)
  assert_true(next.file_panel.highlighted is Some(Relative("")))
}

///|
test "RevealDirectory loads an uncached breadcrumb directory" {
  let dispatch = test_dispatch()
  let model = test_model()
  let panel = {
    ..model.file_panel,
    owner: Some({ channel: Local, session: "desktop-test", }),
  }
  let (_, next) = update(
    dispatch,
    FileEditor(RevealDirectory(Relative("src/foo"))),
    { ..model, file_panel: panel, },
  )
  assert_true(next.file_panel.expanded.is_empty())
  assert_true(next.file_panel.loading.contains(Relative("src/foo")))
  assert_true(next.file_panel.highlighted is Some(Relative("src/foo")))
}

///|
test "RevealDirectory on an already-cached directory needs no reload" {
  let dispatch = test_dispatch()
  let model = test_model()
  let children : Map[@pathx.Relative, Array[@fileeditor.FileEntry]] = Map([
    (Relative("src/foo"), []),
  ])
  let panel = {
    ..model.file_panel,
    owner: Some({ channel: Local, session: "desktop-test", }),
    children,
  }
  let (_, next) = update(
    dispatch,
    FileEditor(RevealDirectory(Relative("src/foo"))),
    { ..model, file_panel: panel, },
  )
  assert_true(next.file_panel.expanded.is_empty())
  assert_false(next.file_panel.loading.contains(Relative("src/foo")))
  assert_true(next.file_panel.highlighted is Some(Relative("src/foo")))
}

///|
test "HighlightCleared only clears a highlight that still matches" {
  let dispatch = test_dispatch()
  let model = test_model()
  // Rooted in the active session, or the post-dispatch `sync` re-roots the
  // panel and clears the highlight itself.
  let panel = {
    ..model.file_panel,
    owner: Some({ channel: Local, session: "desktop-test", }),
    highlighted: Some(Relative("src")),
  }
  let (_, stale) = update(
    dispatch,
    FileEditor(HighlightCleared(Relative("old"))),
    { ..model, file_panel: panel, },
  )
  assert_true(stale.file_panel.highlighted is Some(Relative("src")))
  let (_, cleared) = update(
    dispatch,
    FileEditor(HighlightCleared(Relative("src"))),
    { ..model, file_panel: panel, },
  )
  assert_true(cleared.file_panel.highlighted is None)
}

///|
test "a tree pick fulfills the active picker in place" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(dispatch, ToggleRightPanel, model)
  let (_, model) = update(dispatch, ExplorerRequested(ExplorerFiles), model)
  let (_, model) = update(
    dispatch,
    FileEditor(FileSelected(path=Relative("src/main.mbt"), name="main.mbt")),
    model,
  )
  let model = model.test_resolve_editor("src/main.mbt")
  assert_true(
    model.dock.tabs ==
    [@dock.DockTab::File(path=model.test_file("src/main.mbt"))],
  )
  assert_true(
    @dock.active_file(model.dock) == Some(model.test_file("src/main.mbt")),
  )
}

///|
test "a changed row opens the file tab in review mode" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(dispatch, ToggleRightPanel, model)
  let (_, model) = update(dispatch, ExplorerRequested(ExplorerChanges), model)
  let path = @pathx.Relative("src/main.mbt")
  let (_, model) = update(
    dispatch,
    FileEditor(
      ChangedFileSelected({
        path,
        original_path: None,
        index_status: " ",
        worktree_status: "M",
        kind: ChangeModified,
      }),
    ),
    model,
  )
  assert_true(
    model.dock.tabs == [@dock.DockTab::File(path=model.test_file(path.0))],
  )
  assert_true(@dock.active_file(model.dock) == Some(model.test_file(path.0)))
  assert_true(
    model.file_panel.docs.get(model.test_file(path.0))
    is Some(
      {
        state: TabLoading,
        review: Some({ generation: 1, baseline: ReviewLoading, .. }),
        ..
      }
    ),
  )
}

///|
test "file rows and location jumps cannot open while checkout placement is missing" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/proj")
  let model = desktop_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Worktree(project=workspace, name="wt"),
    })
    .with_dev(dev => {
      ..dev,
      projects: [workspace],
      worktrees: [
        {
          project: workspace,
          rows: [
            {
              name: "wt",
              session: Some("desktop-test"),
              path: None,
              codex_thread: None,
              present: false,
            },
          ],
          generation: 1,
        },
      ],
    })
  let path = @pathx.Relative("src/main.mbt")
  let file = @resource.join_relative(workspace, path)
  let (_, ordinary) = update(
    dispatch,
    FileEditor(FileSelected(path~, name="main.mbt")),
    model,
  )
  assert_false(ordinary.dock.tabs.contains(@dock.DockTab::File(path=file)))
  assert_false(ordinary.file_panel.docs.contains(file))
  let (_, review) = update(
    dispatch,
    FileEditor(
      ChangedFileSelected({
        path,
        original_path: None,
        index_status: " ",
        worktree_status: "M",
        kind: ChangeModified,
      }),
    ),
    model,
  )
  assert_false(review.dock.tabs.contains(@dock.DockTab::File(path=file)))
  assert_false(review.file_panel.docs.contains(file))
  let (_, jumped) = update(
    dispatch,
    JumpToLocation(
      path="/proj/src/main.mbt",
      range=Some(@common.Range(1, 1, 1, 1)),
      annotation=None,
    ),
    model,
  )
  assert_false(jumped.dock.tabs.contains(@dock.DockTab::File(path=file)))
  assert_false(jumped.file_panel.docs.contains(file))
  let (_, navigation) = update(
    dispatch,
    FileEditor(
      OpenNavigationLocation(
        owner=file_ctx(model).owner,
        path~,
        range=@common.Range(1, 1, 1, 1),
      ),
    ),
    model,
  )
  assert_false(navigation.dock.tabs.contains(@dock.DockTab::File(path=file)))
  assert_false(navigation.file_panel.docs.contains(file))
}

///|
test "Search reuses the picker and keeps a request when its Explorer tab leaves" {
  let dispatch = test_dispatch()
  let (_, opened) = update(
    dispatch,
    ExplorerRequested(ExplorerSearch),
    desktop_model(),
  )
  assert_true(opened.right_panel_open)
  assert_true(opened.dock.active is Some(@dock.DockTab::FilePicker))
  assert_true(opened.dock.tabs == [@dock.DockTab::FilePicker])
  assert_true(opened.file_panel.explorer_mode is ExplorerSearch)
  assert_true(opened.file_panel.tree_open)
  let (_, reopened_picker) = update(
    dispatch,
    ExplorerRequested(ExplorerSearch),
    opened,
  )
  assert_true(reopened_picker.dock.tabs == [@dock.DockTab::FilePicker])
  let (_, edited) = update(
    dispatch,
    FileEditor(Search(@grep_search.QueryChanged("moon"))),
    reopened_picker,
  )
  let (_, running) = update(
    dispatch,
    FileEditor(Search(@grep_search.Submit)),
    edited,
  )
  let (_, files) = update(
    dispatch,
    FileEditor(@fileeditor.ExplorerModeSelected(ExplorerFiles)),
    running,
  )
  let (_, reopened) = update(dispatch, ExplorerRequested(ExplorerSearch), files)
  assert_true(reopened.dock.tabs == [@dock.DockTab::FilePicker])
  assert_true(reopened.file_panel.explorer_mode is ExplorerSearch)
}

///|
test "a Search result fulfills the picker while preserving Search beside the file" {
  let dispatch = test_dispatch()
  let (_, opened) = update(
    dispatch,
    ExplorerRequested(ExplorerSearch),
    desktop_model(),
  )
  let (_, edited) = update(
    dispatch,
    FileEditor(Search(@grep_search.QueryChanged("moon"))),
    opened,
  )
  let path = @pathx.Relative("src/main.mbt")
  let file = opened.test_file(path.0)
  let range = @common.Range(4, 2, 4, 6)
  let (_, selected) = update(
    dispatch,
    FileEditor(SearchMatchSelected(path=path.0, range~)),
    edited,
  )
  let selected = selected.test_resolve_editor(path.0)
  assert_true(selected.dock.tabs == [@dock.DockTab::File(path=file)])
  assert_true(@dock.active_file(selected.dock) == Some(file))
  assert_true(selected.file_panel.explorer_mode is ExplorerSearch)
  assert_true(selected.file_panel.tree_open)
  assert_true(
    selected.file_panel.docs.get(file)
    is Some({ review: None, state: TabLoading, .. }),
  )

  // Opening Search again appends the one shared picker. Picking the already
  // open file removes that picker and activates the existing file tab.
  let (_, picker) = update(
    dispatch,
    ExplorerRequested(ExplorerSearch),
    selected,
  )
  assert_true(
    picker.dock.tabs ==
    [@dock.DockTab::File(path=file), @dock.DockTab::FilePicker],
  )
  let (_, reused) = update(
    dispatch,
    FileEditor(SearchMatchSelected(path=path.0, range~)),
    picker,
  )
  let reused = reused.test_resolve_editor(path.0)
  assert_true(reused.dock.tabs == [@dock.DockTab::File(path=file)])
  assert_true(@dock.active_file(reused.dock) == Some(file))
  assert_true(reused.file_panel.explorer_mode is ExplorerSearch)
}

///|
test "narrow Search drill-down hides and restores the retained Explorer" {
  let dispatch = test_dispatch()
  let (_, narrow) = update(
    dispatch,
    ViewportResized(width=390),
    desktop_model(),
  )
  let (_, opened) = update(dispatch, ExplorerRequested(ExplorerSearch), narrow)
  let (_, edited) = update(
    dispatch,
    FileEditor(Search(@grep_search.QueryChanged("needle"))),
    opened,
  )
  let path = @pathx.Relative("src/narrow.mbt")
  let range = @common.Range(1, 1, 1, 7)
  let (_, drilled) = update(
    dispatch,
    FileEditor(SearchMatchSelected(path=path.0, range~)),
    edited,
  )
  let drilled = drilled.test_resolve_editor(path.0)
  assert_true(drilled.file_panel.explorer_mode is ExplorerSearch)
  assert_false(drilled.file_panel.tree_open)
  let (_, restored) = update(
    dispatch,
    FileEditor(@fileeditor.ToggleTree),
    drilled,
  )
  assert_true(restored.file_panel.tree_open)
  assert_true(restored.file_panel.explorer_mode is ExplorerSearch)
}

///|
test "Search requests survive hidden Explorer Browser and panel states" {
  let dispatch = test_dispatch()
  let (_, opened) = update(
    dispatch,
    ExplorerRequested(ExplorerSearch),
    desktop_model(),
  )
  let path = @pathx.Relative("src/main.mbt")
  let range = @common.Range(2, 1, 2, 5)
  let (_, file) = update(
    dispatch,
    FileEditor(SearchMatchSelected(path=path.0, range~)),
    opened,
  )
  let file = file.test_resolve_editor(path.0)
  let (_, edited) = update(
    dispatch,
    FileEditor(Search(@grep_search.QueryChanged("moon"))),
    file,
  )
  let (_, running) = update(
    dispatch,
    FileEditor(Search(@grep_search.Submit)),
    edited,
  )

  let (_, tree_hidden) = update(
    dispatch,
    FileEditor(@fileeditor.ToggleTree),
    running,
  )
  let (_, browser) = update(dispatch, BrowserTabRequested, tree_hidden)
  let (_, panel_closed) = update(dispatch, ToggleRightPanel, browser)
  assert_false(panel_closed.right_panel_open)
}

///|
fn Model::test_resolve_editor(self : Model, path : String) -> Model {
  let owner = file_ctx(self).owner
  let (_, model) = update(
    test_dispatch(),
    OpenPathResolved(
      FileOpenContext::new(owner, self.file_panel.file_link_generation),
      Editor({ path, line: None, column: None, }),
    ),
    self,
  )
  model
}
