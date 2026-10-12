///|
/// A reconnect invalidates every path-based fact: the worktree mirror is
/// dropped, so this conversation's placement is unknown again and nothing may
/// keep addressing the root the dead connection confirmed. Both the watcher
/// and the file index must retire and stay retired until a fresh index is
/// built against a re-confirmed root.
test "a reconnect retires the file index watcher until placement returns" {
  let dispatch = test_dispatch()
  let model = test_model()
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "desktop-test",
  }
  let root = @interop.ChannelId::Local.test_project()
  let watched : @fileeditor.WatchedPaths = {
    owner,
    root,
    files: [],
    directories: [],
    recursive: true,
  }
  let panel = {
    ..model.file_panel,
    owner: Some(owner),
    placement: @fileeditor.PlacementLive(@interop.WorkspaceRoot(root~)),
    watching: Some(watched),
    watch_generation: 7,
  }
  let model = { ..model, file_panel: panel, }
  let file_emit = dispatch.map(msg => FileEditor(msg))
  let (_, loading) = @fileeditor.update(
    file_emit,
    @fileeditor.EnsureFileIndex,
    panel,
    file_ctx(model),
  )
  let (_, ready) = @fileeditor.update(
    file_emit,
    @fileeditor.FilesIndexed(
      owner~,
      epoch=loading.request_epoch,
      files=[],
      truncated=false,
    ),
    loading,
    file_ctx(model),
  )
  let model = { ..model, file_panel: ready, }
  let (_, reconnected) = update_dev(dispatch, BridgeReady, model)
  // A reconnect drops the worktree mirror, so this conversation's placement
  // is unknown again. Both the watcher and the index retire rather than keep
  // addressing a root the new connection has not confirmed.
  assert_true(reconnected.file_panel.watching is None)
  assert_false(reconnected.file_panel.index is @fileeditor.IndexReady(..))
  // The registry answering does not by itself resurrect them: nothing is
  // watched again until a fresh index is built against the confirmed root.
  let (_, placed) = update_dev(
    dispatch,
    WorktreesLoaded(
      [],
      workspace=@interop.ChannelId::Local.test_project(),
      connection_generation=reconnected.dev().connection_generation,
      request_generation=reconnected.dev().worktrees_request_generation,
    ),
    reconnected,
  )
  assert_true(placed.file_panel.watching is None)
  assert_eq(placed.dev().worktrees.length(), 1)
}

///|
test "device focus retires the outgoing watcher and file index" {
  let dispatch = test_dispatch()
  let remote : @interop.ChannelId = Remote("remote-device")
  let model = test_model()
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "desktop-test",
  }
  let root = @interop.ChannelId::Local.test_project()
  let devices = model.devices.copy()
  devices.push({ ..empty_device_state(remote), bridge: Connected, })
  let conversations = model.conversations.copy()
  conversations.push(
    empty_conversation(remote, "remote-session", remote.test_project()),
  )
  let panel = {
    ..model.file_panel,
    owner: Some(owner),
    placement: @fileeditor.PlacementLive(@interop.WorkspaceRoot(root~)),
    watching: Some({ owner, root, files: [], directories: [], recursive: true, }),
    watch_generation: 7,
  }
  let model = { ..model, devices, conversations, file_panel: panel, }
  let (_, loading) = @fileeditor.update(
    dispatch.map(msg => FileEditor(msg)),
    @fileeditor.EnsureFileIndex,
    panel,
    file_ctx(model),
  )
  assert_true(loading.index is @fileeditor.IndexLoading(_))
  let (_, next) = update(dispatch, OpenSession(remote, "remote-session"), {
    ..model,
    file_panel: loading,
  })
  // The old Local HostConnection receives `fs.unwatch` before the common sync
  // replaces its owner. That sync also retires the in-flight Local index key;
  // the new remote conversation starts without either resource.
  assert_eq(next.focused, remote)
  assert_true(
    next.file_panel.owner is Some({ channel: Remote("remote-device"), .. }),
  )
  assert_true(next.file_panel.watching is None)
  assert_eq(next.file_panel.watch_generation, 8)
  assert_true(next.file_panel.index is @fileeditor.IndexEmpty)
}

///|
test "file editor context reports the file body actual visibility" {
  let model = test_model()
  let path = @pathx.Relative("src/main.mbt")
  let file_model = {
    ..model,
    right_panel_open: true,
    dock: {
      ..model.dock,
      tabs: [File(path=model.test_file(path.0))],
      active: Some(File(path=model.test_file(path.0))),
    },
  }
  assert_true(file_ctx(file_model).panel_open)
  assert_false(file_ctx({ ..file_model, right_panel_open: false, }).panel_open)
  let picker_model = {
    ..file_model,
    dock: { ..file_model.dock, tabs: [FilePicker], active: Some(FilePicker), },
  }
  assert_true(file_ctx(picker_model).panel_open)
  let browser_model = {
    ..file_model,
    dock: {
      ..file_model.dock,
      tabs: [Browser(id=1)],
      active: Some(Browser(id=1)),
    },
  }
  assert_false(file_ctx(browser_model).panel_open)
  let launcher_model = {
    ..file_model,
    dock: { ..file_model.dock, tabs: [], active: None, },
  }
  assert_false(file_ctx(launcher_model).panel_open)
  assert_false(file_ctx({ ..file_model, screen: Skills, }).panel_open)
  assert_false(file_ctx({ ..file_model, screen: Settings, }).panel_open)
}

///|
test "only synchronous file-open messages suppress panel reactivation" {
  let owner : @interop.ConversationKey = {
    channel: Local,
    session: "desktop-test",
  }
  let identity : ComposerActionIdentity = { owner, archive_generation: 0, }
  assert_false(
    ComposerAction(
      @composer.MentionOpened(identity~, mention={
        ref_: File(path="a.mbt"),
        range: None,
      }),
    ).opens_file_before_panel_reconciliation(),
  )
  assert_false(
    CodexComposerAction(
      @composer.MentionOpened(identity~, mention={
        ref_: File(path="a.mbt"),
        range: None,
      }),
    ).opens_file_before_panel_reconciliation(),
  )
  assert_false(
    JumpToLocation(path="a.mbt", range=None, annotation=None).opens_file_before_panel_reconciliation(),
  )
  assert_false(
    QuickOpen(@quick_open.Pick(0)).opens_file_before_panel_reconciliation(),
  )
  assert_true(
    OpenPathResolved(
      FileOpenContext::new(owner, 1),
      Editor({ path: "a.mbt", line: Some(1), column: None, }),
    ).opens_file_before_panel_reconciliation(),
  )
  // This only starts the asynchronous host lookup. The later OpenPathResolved is
  // the message that actually opens the document.
  assert_false(OpenFile("a.mbt").opens_file_before_panel_reconciliation())
  assert_false(ToggleRightPanel.opens_file_before_panel_reconciliation())
}

///|
test "language request failures toast once and remain conversation fenced" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let owner = file_ctx(model).owner
  let msg = FileEditor(
    @fileeditor.LanguageRequestFailed(
      owner~,
      message="Go to definition failed: workspace index is unavailable",
    ),
  )
  let (_, first) = update(dispatch, msg, model)
  let (_, same_input) = update(dispatch, msg, model)
  assert_true(first.notifications == same_input.notifications)
  assert_eq(first.notification_seq, same_input.notification_seq)
  assert_eq(first.notifications.length(), 1)
  assert_eq(
    first.notifications[0].message,
    "Go to definition failed: workspace index is unavailable",
  )
  let (_, repeated) = update(dispatch, msg, first)
  assert_eq(repeated.notifications.length(), 1)
  let (_, stale) = update(
    dispatch,
    FileEditor(
      @fileeditor.LanguageRequestFailed(
        owner={ channel: Local, session: "another-conversation", },
        message="late failure",
      ),
    ),
    repeated,
  )
  assert_true(stale.notifications == repeated.notifications)
}

///|
test "file watcher failures toast once and retain lifecycle state" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let owner = file_ctx(model).owner
  let root = @interop.ChannelId::Local.test_project()
  let generation = 7
  let panel = {
    ..model.file_panel,
    owner: Some(owner),
    placement: @fileeditor.PlacementLive(@interop.WorkspaceRoot(root~)),
    watching: Some({ owner, root, files: [], directories: [], recursive: true, }),
    watch_generation: generation,
  }
  let model = { ..model, file_panel: panel, }
  // A live index keeps the recursive watcher desired while the file pane is
  // closed, so the root update's ordinary sync pass preserves this failure.
  let file_emit = dispatch.map(next => FileEditor(next))
  let (_, loading) = @fileeditor.update(
    file_emit,
    @fileeditor.EnsureFileIndex,
    panel,
    file_ctx(model),
  )
  let (_, ready) = @fileeditor.update(
    file_emit,
    @fileeditor.FilesIndexed(
      owner~,
      epoch=loading.request_epoch,
      files=[],
      truncated=false,
    ),
    loading,
    file_ctx(model),
  )
  let model = { ..model, file_panel: ready, }
  let message = "File watching stopped: too many open files"
  let failure = FileEditor(
    @fileeditor.FileWatchFailed(
      channel=owner.channel,
      root~,
      generation="\{file_ctx(model).watch_namespace}:\{generation}",
      message~,
    ),
  )
  let (_, failed) = update(dispatch, failure, model)
  assert_eq(failed.file_panel.watch_error, Some(message))
  assert_eq(failed.notifications.length(), 1)
  assert_eq(failed.notifications[0].message, message)
  // The same current-generation notification neither mutates watcher state
  // again nor stacks another toast while the first one is still visible.
  let (_, repeated) = update(dispatch, failure, failed)
  assert_eq(repeated.file_panel.watch_error, Some(message))
  assert_eq(repeated.notifications.length(), 1)
  // The file-editor package rejects a failure from another concrete watcher;
  // the root therefore has no accepted failure to announce.
  let (_, stale) = update(
    dispatch,
    FileEditor(
      @fileeditor.FileWatchFailed(
        channel=owner.channel,
        root~,
        generation="\{file_ctx(model).watch_namespace}:\{generation - 1}",
        message="stale watcher failure",
      ),
    ),
    repeated,
  )
  assert_eq(stale.file_panel.watch_error, Some(message))
  assert_eq(stale.notifications.length(), 1)
}
