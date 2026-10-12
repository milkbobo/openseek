///|
test "opening an archived row creates a read-only transcript owner" {
  let dispatch = test_dispatch()
  let item = archived_item("desktop-archived")
  let model = test_model().with_dev(dev => { ..dev, archived: [item], })
  let open = OpenArchivedSession(
    @interop.ChannelId::Local,
    session=item.id,
    workspace=item.workspace,
  )
  let (_, loading) = update(dispatch, open, model)
  inspect(loading.active_session, content="desktop-archived")
  assert_true(loading.active().record is ArchivedRecord)
  guard loading.active().sync is Reloading(generation=1, attempt=1, ..) else {
    fail("the archived transcript did not begin its first read")
  }
  assert_true(
    loading.loading_conversation
    is Some({ channel: Local, session: "desktop-archived", }),
  )
  // Re-selecting the same row stays single-flight; it does not mint a second
  // generation that could overtake the first archived snapshot.
  let (_, selected_again) = update(dispatch, open, loading)
  guard selected_again.active().sync is Reloading(generation=1, ..) else {
    fail("re-selecting an archived row replaced the in-flight generation")
  }
}

///|
test "switching same-id archived stores fences the first transcript load" {
  let dispatch = test_dispatch()
  let first = @interop.ChannelId::Local.test_resource("/first")
  let second = @interop.ChannelId::Local.test_resource("/second")
  let first_item : @transcript.SessionListItem = {
    ..archived_item("desktop-shared"),
    workspace: first,
    workspace_name: "first",
    updated_at_ms: None,
  }
  let second_item : @transcript.SessionListItem = {
    ..first_item,
    workspace: second,
    workspace_name: "second",
    updated_at_ms: None,
  }
  let model = test_model().with_dev(dev => {
    ..dev,
    archived: [first_item, second_item],
    projects: [first, second],
  })
  let (_, loading_first) = update(
    dispatch,
    OpenArchivedSession(
      @interop.ChannelId::Local,
      session=first_item.id,
      workspace=first_item.workspace,
    ),
    model,
  )
  guard loading_first.active().sync is Reloading(generation=1, ..) else {
    fail("the first archived store did not begin loading")
  }
  assert_eq(loading_first.active().workspace, Project(root=first))
  let (_, loading_second) = update(
    dispatch,
    OpenArchivedSession(
      @interop.ChannelId::Local,
      session=second_item.id,
      workspace=second_item.workspace,
    ),
    loading_first,
  )
  guard loading_second.active().sync is Reloading(generation=2, ..) else {
    fail("the second archived store reused the first request generation")
  }
  assert_eq(loading_second.active().workspace, Project(root=second))
  let (_, stale_first) = update_dev(
    dispatch,
    SessionLoaded(
      session=first_item.id,
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("first store answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: Some(1),
        },
      ],
      watermark=1,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation=1,
    ),
    loading_second,
  )
  inspect(stale_first.active().messages.length(), content="0")
  assert_eq(stale_first.active().workspace, Project(root=second))
  let (_, loaded_second) = update_dev(
    dispatch,
    SessionLoaded(
      session=second_item.id,
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("second store answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: Some(1),
        },
      ],
      watermark=1,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation=2,
    ),
    stale_first,
  )
  inspect(loaded_second.active().messages.length(), content="1")
  assert_eq(
    loaded_second.active().messages[0].text(),
    Some("second store answer"),
  )
}

///|
test "archived transcripts reject record-changing actions in update" {
  let dispatch = test_dispatch()
  let archived = {
    ..test_conversation(),
    record: ArchivedRecord,
    task: "must stay unsent",
    goal_edit: Some({ draft: "must stay unset", }),
  }
  let model = test_model().replace_conversation(archived)
  let (_, sent) = update(dispatch, Send, model)
  assert_true(sent.active().run is NoRun(ended=None))
  inspect(sent.active().task, content="must stay unsent")
  let (_, goal) = update(dispatch, SubmitGoal, model)
  assert_true(goal.active().goal_pending is None)
  assert_true(goal.active().goal_edit is Some(_))
  let (_, compacted) = run_slash_command(dispatch, model, "compact")
  assert_true(compacted.active().compaction is NotCompacting)
  inspect(compacted.active().task, content="must stay unsent")
}

///|
test "an archived snapshot stays open across archived-list reconciliation" {
  let dispatch = test_dispatch()
  let item = archived_item("desktop-archived")
  let model = test_model().with_dev(dev => { ..dev, archived: [item], })
  let (_, loading) = update(
    dispatch,
    OpenArchivedSession(
      @interop.ChannelId::Local,
      session=item.id,
      workspace=item.workspace,
    ),
    model,
  )
  let (_, loaded) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session=item.id,
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("archived answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: Some(1),
        },
      ],
      watermark=1,
      generation=1,
    ),
    loading,
  )
  assert_true(loaded.active().record is ArchivedRecord)
  assert_eq(loaded.active().messages[0].text(), Some("archived answer"))
  let (_, reconciled) = update(dispatch, archived_loaded([item]), loaded)
  inspect(reconciled.active_session, content="desktop-archived")
  assert_true(reconciled.active().record is ArchivedRecord)
  assert_eq(reconciled.active().messages[0].text(), Some("archived answer"))
}

///|
test "unarchiving an open transcript fences its archived snapshot" {
  let dispatch = test_dispatch()
  let item = archived_item("desktop-archived")
  let archived = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      item.id,
      @interop.ChannelId::Local.test_project(),
    ),
    record: ArchivedRecord,
    messages: [
      {
        kind: Assistant(
          reasoning=None,
          prose=Some("visible archived answer"),
          calls=[],
          replay=false,
          finished=false,
        ),
        ts: None,
        sequence: Some(1),
      },
    ],
    watermark: 1,
  }
  let model = {
    ..test_model()
    .replace_conversation(archived)
    .with_dev(dev => { ..dev, archived: [item], }),
    active_session: item.id,
    transcript_request_generation: 1,
  }
  let (_, restoring) = update_dev(
    dispatch,
    SessionsChanged(
      change="unarchived",
      key={ session: item.id, workspace: item.workspace, },
      fresh_session=None,
    ),
    model,
  )
  assert_true(restoring.active().record is LiveRecord)
  guard restoring.active().sync is Reloading(generation=2, ..) else {
    fail("unarchive did not fence the archived read with a live generation")
  }
  let (_, stale) = update_dev(
    dispatch,
    SessionLoaded(
      goal=None,
      goal_markers=[],
      prediction=None,
      session=item.id,
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("late archived answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: Some(1),
        },
      ],
      watermark=1,
      generation=1,
    ),
    restoring,
  )
  assert_true(stale.active().record is LiveRecord)
  assert_eq(stale.active().messages[0].text(), Some("visible archived answer"))
}

///|
test "session.changed decoder preserves archive invalidation identity" {
  let store = @interop.ChannelId::Local.test_project()
  guard session_changed_msg(@interop.ChannelId::Local, {
      change: "archived",
      session: "desktop-old",
      workspace: store.path,
    })
    is Some(
      SessionsChanged(change="archived", key=archived, fresh_session=Some(_))
    ) else {
    fail("archive invalidation was not decoded")
  }
  assert_true(archived == { session: "desktop-old", workspace: store, })
  guard session_changed_msg(@interop.ChannelId::Local, {
      change: "deleted",
      session: "desktop-old",
      workspace: store.path,
    })
    is Some(
      SessionsChanged(change="deleted", key=deleted, fresh_session=Some(_))
    ) else {
    fail("delete invalidation was not decoded")
  }
  assert_true(deleted == { session: "desktop-old", workspace: store, })
  // Every durable record lives in a workspace store, so a notification that
  // names none identifies no record and is refused outright.
  assert_true(
    session_changed_msg(@interop.ChannelId::Local, {
      change: "archived",
      session: "desktop-old",
      workspace: "",
    })
    is None,
  )
}

///|
test "archived deletion confirmation owns one visible conversation family" {
  let dispatch = test_dispatch()
  let parent = archived_item("desktop-parent")
  let child = archived_item("desktop-parent-sr-1")
  let model = test_model().with_dev(dev => {
    ..dev,
    archived: [parent, child, archived_item("desktop-other")],
  })
  let (_, staged) = update(
    dispatch,
    DeleteArchivedSession(@interop.ChannelId::Local, {
      session: "desktop-parent",
      workspace: @interop.ChannelId::Local.test_project(),
    }),
    model,
  )
  guard staged.archived_delete_confirm is Some(confirm) else {
    fail("delete confirmation was not staged")
  }
  assert_true(
    confirm.key ==
    {
      session: "desktop-parent",
      workspace: @interop.ChannelId::Local.test_project(),
    },
  )
  // The record's blank title falls back to its id: the dialog names what the
  // archived list showed, not whatever label the click happened to carry.
  assert_eq(confirm.title, "desktop-parent")
  assert_true(confirm.sessions.contains("desktop-parent"))
  assert_true(confirm.sessions.contains("desktop-parent-sr-1"))
  let (_, cancelled) = update(dispatch, CancelDeleteArchivedSession, staged)
  assert_true(cancelled.archived_delete_confirm is None)
  let (_, cancelled_twice) = update(
    dispatch,
    CancelDeleteArchivedSession,
    cancelled,
  )
  assert_true(cancelled_twice.archived_delete_confirm is None)
  let (_, confirmed) = update(dispatch, ConfirmDeleteArchivedSession, staged)
  assert_true(confirmed.archived_delete_confirm is None)
  assert_eq(confirmed.dev().archived_request_generation, 1)
  let (_, confirmed_twice) = update(
    dispatch,
    ConfirmDeleteArchivedSession,
    confirmed,
  )
  assert_eq(confirmed_twice.dev().archived_request_generation, 1)
}

///|
test "archived deletion keeps same-id rows in other stores" {
  let dispatch = test_dispatch()
  let project = @interop.ChannelId::Local.test_resource("/project")
  let unplaced = archived_item("shared")
  let project_parent : @transcript.SessionListItem = {
    ..archived_item("shared"),
    workspace: project,
    workspace_name: "project",
    updated_at_ms: None,
  }
  let project_child : @transcript.SessionListItem = {
    ..project_parent,
    id: "shared-sr-1",
  }
  // The other store's live row deliberately comes first. Store-qualified
  // active deletion must use the open conversation, not this same-id row.
  let model = {
    ..test_model()
    .replace_conversation({
      ..empty_conversation(
        @interop.ChannelId::Local,
        "shared",
        @interop.ChannelId::Local.test_project(),
      ),
      workspace: Project(root=project),
      record: ArchivedRecord,
      task: "project draft",
    })
    .with_dev(dev => {
      ..dev,
      sessions: [unplaced],
      archived: [unplaced, project_parent, project_child],
    }),
    active_session: "shared",
  }
  let key : ArchiveRecordKey = { session: "shared", workspace: project, }
  let (_, staged) = update(
    dispatch,
    DeleteArchivedSession(@interop.ChannelId::Local, key),
    model,
  )
  guard staged.archived_delete_confirm is Some(confirm) else {
    fail("delete confirmation was not staged")
  }
  assert_true(confirm.key == key)
  assert_eq(confirm.sessions, ["shared", "shared-sr-1"])
  let response_model = staged.with_dev(dev => {
    ..dev,
    archived_request_generation: 1,
  })
  let (_, deleted) = update_dev(
    dispatch,
    ArchivedDeleted(
      key~,
      sessions=confirm.sessions,
      items=[unplaced, project_parent, project_child],
      connection_generation=0,
      request_generation=1,
      fresh_session="desktop-fresh",
    ),
    response_model,
  )
  assert_true(deleted.dev().archived == [unplaced])
  inspect(deleted.active_session, content="desktop-fresh")
  inspect(deleted.active().task, content="")
}

///|
test "delete response tombstones a family before stale list replies" {
  let dispatch = test_dispatch()
  let parent = archived_item("desktop-parent")
  let child = archived_item("desktop-parent-sr-1")
  let other = archived_item("desktop-other")
  let model = {
    ..test_model().with_dev(dev => {
      ..dev,
      archived_request_generation: 1,
      archived: [parent, child, other],
      sessions: [parent, child],
    }),
    conversations: [
      {
        ..empty_conversation(
          @interop.ChannelId::Local,
          "desktop-parent",
          @interop.ChannelId::Local.test_project(),
        ),
        record: ArchivedRecord,
        task: "keep local draft",
      },
      empty_conversation(
        @interop.ChannelId::Local,
        "desktop-parent-sr-1",
        @interop.ChannelId::Local.test_project(),
      ),
    ],
    active_session: "desktop-parent",
  }
  let deleted_msg = ArchivedDeleted(
    key={
      session: "desktop-parent",
      workspace: @interop.ChannelId::Local.test_project(),
    },
    sessions=["desktop-parent", "desktop-parent-sr-1"],
    items=[parent, child, other],
    connection_generation=0,
    request_generation=1,
    fresh_session="desktop-fresh",
  )
  let (_, deleted) = update_dev(dispatch, deleted_msg, model)
  let (_, same_input) = update_dev(dispatch, deleted_msg, model)
  inspect(deleted.active_session, content="desktop-fresh")
  assert_eq(same_input.active_session, deleted.active_session)
  assert_eq(same_input.active().task, deleted.active().task)
  inspect(deleted.active().task, content="")
  assert_eq(deleted.dev().archived.length(), 1)
  assert_eq(deleted.dev().archived[0].id, "desktop-other")
  assert_false(deleted.dev().sessions.contains(parent))
  assert_false(deleted.dev().sessions.contains(child))
  assert_true(
    deleted.find_conversation(@interop.ChannelId::Local, "desktop-parent")
    is None,
  )
  assert_true(
    deleted.find_conversation(@interop.ChannelId::Local, "desktop-parent-sr-1")
    is None,
  )
  let (_, stale_live) = update_dev(
    dispatch,
    SessionsLoaded(
      [parent, child],
      connection_generation=0,
      request_generation=0,
    ),
    deleted,
  )
  assert_false(stale_live.dev().sessions.contains(parent))
  assert_false(stale_live.dev().sessions.contains(child))
}

///|
test "a new Started incarnation retires its exact deleted tombstone" {
  let dispatch = test_dispatch()
  let deleted_item = archived_item("desktop-recreated")
  let project = @interop.ChannelId::Local.test_resource("/project")
  let model = test_model().with_dev(dev => {
    ..dev,
    archived_request_generation: 1,
    archived: [deleted_item],
    projects: [project],
  })
  let (_, deleted) = update_dev(
    dispatch,
    ArchivedDeleted(
      key={
        session: deleted_item.id,
        workspace: @interop.ChannelId::Local.test_project(),
      },
      sessions=[deleted_item.id],
      items=[deleted_item],
      connection_generation=0,
      request_generation=1,
      fresh_session="desktop-fresh",
    ),
    model,
  )
  assert_true(
    deleted
    .dev()
    .archive_override({
      session: deleted_item.id,
      workspace: @interop.ChannelId::Local.test_project(),
    })
    is Some(ArchiveDeleted),
  )
  // A same-id creation in another store is unrelated and cannot lift the
  // tombstone selected here.
  let (_, unrelated) = update_dev(
    dispatch,
    Started(
      run_id="unrelated-run",
      session=deleted_item.id,
      model=DsPro,
      max_steps=1000,
      session_root=Some(
        @interop.ChannelId::Local.test_resource("/project/.openseek"),
      ),
      submission_id=None,
    ),
    deleted,
  )
  assert_true(
    unrelated
    .dev()
    .archive_override({
      session: deleted_item.id,
      workspace: @interop.ChannelId::Local.test_project(),
    })
    is Some(ArchiveDeleted),
  )
  let (_, started) = update_dev(
    dispatch,
    Started(
      run_id="recreated-run",
      session=deleted_item.id,
      model=DsPro,
      max_steps=1000,
      session_root=Some(@interop.ChannelId::Local.test_store_root()),
      submission_id=None,
    ),
    deleted,
  )
  assert_true(
    started
    .dev()
    .archive_override({
      session: deleted_item.id,
      workspace: @interop.ChannelId::Local.test_project(),
    })
    is Some(ArchiveLive),
  )
  let (_, committed) = update_dev(
    dispatch,
    SessionCommitted(
      session=deleted_item.id,
      sequence=1,
      ts=None,
      item=@protocol.User({
        content: Content([Text("new incarnation")]),
        submission_id: None,
      }),
      session_root=@interop.ChannelId::Local.test_store_root(),
    ),
    started,
  )
  guard committed.find_conversation(@interop.ChannelId::Local, deleted_item.id)
    is Some(recreated) else {
    fail("the recreated conversation stayed hidden")
  }
  guard recreated.sync is Reloading(generation~, buffered~, ..) else {
    fail("the recreated conversation did not retain its first commit")
  }
  inspect(buffered.length(), content="1")
  inspect(buffered[0].sequence, content="1")
  let (_, reconciled) = update_dev(
    dispatch,
    SessionRefreshed(
      session=deleted_item.id,
      items=[],
      watermark=0,
      goal=None,
      goal_markers=[],
      prediction=None,
      generation~,
    ),
    committed,
  )
  guard reconciled.find_conversation(@interop.ChannelId::Local, deleted_item.id)
    is Some(recreated) else {
    fail("the recreated conversation disappeared after its snapshot")
  }
  assert_true(
    recreated.messages.any(message => message.text() == Some("new incarnation")),
  )
}

///|
test "deleted broadcast is immediate and idempotent" {
  let dispatch = test_dispatch()
  let item = archived_item("desktop-gone")
  let project = @interop.ChannelId::Local.test_resource("/project")
  let same_id_project : @transcript.SessionListItem = {
    ..item,
    workspace: project,
    workspace_name: "project",
    updated_at_ms: None,
  }
  let model = {
    ..test_model()
    .replace_conversation({
      ..empty_conversation(
        @interop.ChannelId::Local,
        "desktop-gone",
        @interop.ChannelId::Local.test_project(),
      ),
      record: ArchivedRecord,
      task: "carry this draft",
    })
    .with_dev(dev => {
      ..dev,
      sessions: [item, same_id_project],
      archived: [item, same_id_project],
    }),
    active_session: "desktop-gone",
  }
  let deleted_msg = SessionsChanged(
    change="deleted",
    key={
      session: "desktop-gone",
      workspace: @interop.ChannelId::Local.test_project(),
    },
    fresh_session=Some("desktop-fresh"),
  )
  let (_, deleted) = update_dev(dispatch, deleted_msg, model)
  let (_, same_input) = update_dev(dispatch, deleted_msg, model)
  inspect(deleted.active_session, content="desktop-fresh")
  assert_eq(same_input.active_session, deleted.active_session)
  assert_eq(same_input.active().task, deleted.active().task)
  inspect(deleted.active().task, content="")
  assert_true(
    deleted.find_conversation(@interop.ChannelId::Local, "desktop-gone") is None,
  )
  assert_false(deleted.dev().sessions.contains(item))
  assert_false(deleted.dev().archived.contains(item))
  assert_true(deleted.dev().sessions.contains(same_id_project))
  assert_true(deleted.dev().archived.contains(same_id_project))
  let (_, deleted_twice) = update_dev(dispatch, deleted_msg, deleted)
  assert_false(deleted_twice.dev().sessions.contains(item))
  assert_false(deleted_twice.dev().archived.contains(item))
}

///|
test "deleted broadcast rotates the active conversation's exact store" {
  let dispatch = test_dispatch()
  let unplaced = archived_item("shared")
  let project = @interop.ChannelId::Local.test_resource("/project")
  let project_item : @transcript.SessionListItem = {
    ..unplaced,
    workspace: project,
    workspace_name: "project",
    updated_at_ms: None,
  }
  let model = {
    ..test_model()
    .replace_conversation({
      ..empty_conversation(
        @interop.ChannelId::Local,
        "shared",
        @interop.ChannelId::Local.test_project(),
      ),
      workspace: Project(root=project),
      record: ArchivedRecord,
      task: "project draft",
    })
    .with_dev(dev => { ..dev, sessions: [unplaced], archived: [project_item], }),
    active_session: "shared",
  }
  let (_, deleted) = update_dev(
    dispatch,
    SessionsChanged(
      change="deleted",
      key={ session: "shared", workspace: project, },
      fresh_session=Some("desktop-fresh"),
    ),
    model,
  )
  inspect(deleted.active_session, content="desktop-fresh")
  inspect(deleted.active().task, content="")
  assert_true(deleted.dev().sessions == [unplaced])
  assert_true(deleted.dev().archived.is_empty())
}

///|
test "archive facts rotate the open conversation's exact store" {
  let dispatch = test_dispatch()
  let unplaced = archived_item("shared")
  let project = @interop.ChannelId::Local.test_resource("/project")
  let project_item : @transcript.SessionListItem = {
    ..unplaced,
    workspace: project,
    workspace_name: "project",
    updated_at_ms: None,
  }
  // The other store's row deliberately comes first: session_project("shared")
  // resolves to it, while the conversation actually open on screen belongs to
  // the project store being archived.
  let model = {
    ..test_model()
    .replace_conversation({
      ..empty_conversation(
        @interop.ChannelId::Local,
        "shared",
        @interop.ChannelId::Local.test_project(),
      ),
      workspace: Project(root=project),
      task: "project draft",
    })
    .with_dev(dev => { ..dev, sessions: [unplaced, project_item], }),
    active_session: "shared",
  }
  let (_, notified) = update_dev(
    dispatch,
    SessionsChanged(
      change="archived",
      key={ session: "shared", workspace: project, },
      fresh_session=Some("notification-fresh"),
    ),
    model,
  )
  inspect(notified.active_session, content="notification-fresh")
  inspect(notified.active().task, content="")
  assert_true(
    notified.find_conversation(@interop.ChannelId::Local, "shared") is None,
  )
  assert_true(notified.dev().sessions == [unplaced])
  let (_, listed) = update(dispatch, archived_loaded([project_item]), model)
  inspect(listed.active_session, content="desktop-archive-replacement")
  inspect(listed.active().task, content="")
  assert_true(
    listed.find_conversation(@interop.ChannelId::Local, "shared") is None,
  )
  assert_true(listed.dev().sessions == [unplaced])
}

///|
test "archive broadcast invalidates the active send target before list replies" {
  let dispatch = test_dispatch()
  let workspace = @interop.ChannelId::Local.test_resource("/work/archived")
  let mention : Mention = { ref_: Skill(name="draft-skill"), range: None, }
  // The open conversation, not the sidebar row below, is the store owner
  // that the archive notification must retire.
  let model = test_model()
    .replace_conversation({
      ..test_conversation(),
      workspace: Project(root=workspace),
      task: "must not target archived session",
      mentions: [mention],
    })
    .with_dev(dev => {
      ..dev.with_workspace_settings(workspace, true, generation=1),
      sessions: [
        {
          ..placed_archived_item("desktop-test"),
          workspace,
          workspace_name: "archived",
          updated_at_ms: None,
        },
      ],
      worktrees: [{ project: workspace, rows: [], generation: 1, }],
    })
  let (_, invalidated) = update_dev(
    dispatch,
    SessionsChanged(
      change="archived",
      key={ session: "desktop-test", workspace, },
      fresh_session=Some("desktop-fresh"),
    ),
    model,
  )
  inspect(invalidated.active_session, content="desktop-fresh")
  assert_true(
    invalidated.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is None,
  )
  inspect(invalidated.active().session_id, content="desktop-fresh")
  assert_eq(invalidated.dev().active_project, Some(workspace))
  assert_eq(invalidated.active().workspace, Project(root=workspace))
  assert_true(invalidated.active().worktree_mode)
  inspect(invalidated.active().task, content="")
  assert_true(invalidated.active().mentions.is_empty())
  assert_true(invalidated.dev().archived.any(item => item.id == "desktop-test"))
  assert_false(
    invalidated.dev().sessions.any(item => item.id == "desktop-test"),
  )
  // Even before either sidebar refresh returns, the next submit belongs to
  // the replacement conversation; no live state can target the archived id.
  let drafted = invalidated.replace_conversation({
    ..invalidated.active(),
    task: "safe replacement",
  })
  let (_, sent) = update(dispatch, Send, drafted)
  inspect(sent.active_session, content="desktop-fresh")
  inspect(sent.active().session_id, content="desktop-fresh")
  assert_true(sent.active().run is Starting(..))
  assert_true(
    sent.find_conversation(@interop.ChannelId::Local, "desktop-test") is None,
  )
}

///|
test "an archive response arriving before its notification discards the draft once" {
  let dispatch = test_dispatch()
  let model = test_model()
    .replace_conversation({ ..test_conversation(), task: "keep this draft", })
    .with_dev(dev => {
      ..dev,
      sessions: [placed_archived_item("desktop-test")],
    })
  let (_, responded) = update(
    dispatch,
    archived_loaded([placed_archived_item("desktop-test")]),
    model,
  )
  inspect(responded.active_session, content="desktop-archive-replacement")
  inspect(responded.active().task, content="")
  let (_, notified) = update_dev(
    dispatch,
    SessionsChanged(
      change="archived",
      key={
        session: "desktop-test",
        workspace: @interop.ChannelId::Local.test_project(),
      },
      fresh_session=Some("desktop-notification-replacement"),
    ),
    responded,
  )
  // The late duplicate only refreshes the tombstone; it cannot rotate the
  // fallback composer a second time.
  inspect(notified.active_session, content="desktop-archive-replacement")
  inspect(notified.active().task, content="")
}

///|
test "archiving a pending start discards its composer without ownership" {
  let dispatch = test_dispatch()
  let sent_mention : Mention = { ref_: Skill(name="sent-skill"), range: None, }
  let newer_mention : Mention = {
    ref_: Skill(name="newer-skill"),
    range: None,
  }
  let pending = {
    ..test_conversation(),
    pending_prompt: Some({
      images: [],
      submission_id: "pending-start",
      draft: "original draft",
      mentions: [sent_mention],
    }),
  }
  let model = test_model()
    .replace_conversation({
      ..pending,
      run: Starting(submission_id="pending-start"),
      task: "typed afterward",
      mentions: [newer_mention],
    })
    .with_dev(dev => {
      ..dev,
      sessions: [placed_archived_item("desktop-test")],
    })
  let (_, next) = update_dev(
    dispatch,
    SessionsChanged(
      change="archived",
      key={
        session: "desktop-test",
        workspace: @interop.ChannelId::Local.test_project(),
      },
      fresh_session=Some("desktop-restored"),
    ),
    model,
  )
  inspect(next.active_session, content="desktop-restored")
  inspect(next.active().task, content="")
  assert_true(next.active().mentions.is_empty())
  assert_true(next.active().run is NoRun(ended=None))
  inspect(next.active().pending_steers.length(), content="0")
}

///|
test "an archive notification wins over a stale live-list reply" {
  let dispatch = test_dispatch()
  let item = placed_archived_item("desktop-test")
  let model = test_model().with_dev(dev => { ..dev, sessions: [item], })
  let (_, invalidated) = update_dev(
    dispatch,
    SessionsChanged(
      change="archived",
      key={
        session: "desktop-test",
        workspace: @interop.ChannelId::Local.test_project(),
      },
      fresh_session=Some("desktop-safe"),
    ),
    model,
  )
  let (_, stale) = update(
    dispatch,
    sessions_loaded([item], request_generation=1),
    invalidated,
  )
  assert_false(stale.dev().sessions.any(current => current.id == item.id))
  assert_true(stale.dev().archived.any(current => current.id == item.id))
  inspect(stale.active_session, content="desktop-safe")
}

///|
test "a background archive removes only its channel's same-id conversation" {
  let dispatch = test_dispatch()
  let remote : @interop.ChannelId = Remote("d-remote")
  let local_conv = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "shared",
      @interop.ChannelId::Local.test_project(),
    ),
    messages: [
      {
        kind: User(content=Content([Text("local")])),
        ts: None,
        sequence: None,
      },
    ],
  }
  let remote_conv = {
    ..empty_conversation(remote, "shared", remote.test_project()),
    messages: [
      {
        kind: User(content=Content([Text("remote")])),
        ts: None,
        sequence: None,
      },
    ],
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
      ArchivedLoaded(
        [archived_item("shared", channel=remote)],
        connection_generation=0,
        request_generation=0,
        fresh_session="remote-fresh",
      ),
    ),
    model,
  )
  assert_true(next.focused is Local)
  inspect(next.active_session, content="shared")
  guard next.find_conversation(@interop.ChannelId::Local, "shared")
    is Some(kept) else {
    fail("the focused same-id conversation was removed")
  }
  assert_eq(kept.messages[0].text(), Some("local"))
  assert_true(next.find_conversation(remote, "shared") is None)
}

///|
test "an unarchive notification wins over a stale archived-list reply" {
  let dispatch = test_dispatch()
  let item = archived_item("desktop-old")
  let model = test_model().with_dev(dev => { ..dev, archived: [item], })
  let (_, restored) = update_dev(
    dispatch,
    SessionsChanged(
      change="unarchived",
      key={
        session: "desktop-old",
        workspace: @interop.ChannelId::Local.test_project(),
      },
      fresh_session=None,
    ),
    model,
  )
  let (_, stale) = update(
    dispatch,
    archived_loaded([item], request_generation=1),
    restored,
  )
  assert_false(stale.dev().archived.any(current => current.id == item.id))
  assert_true(stale.dev().sessions.any(current => current.id == item.id))
}

///|
test "BridgeReady replaces archive overrides with fresh-list truth" {
  let dispatch = test_dispatch()
  let item = archived_item("desktop-old")
  let archived = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      item.id,
      @interop.ChannelId::Local.test_project(),
    ),
    record: ArchivedRecord,
    messages: [
      {
        kind: Assistant(
          reasoning=None,
          prose=Some("cached archived answer"),
          calls=[],
          replay=false,
          finished=false,
        ),
        ts: None,
        sequence: Some(1),
      },
    ],
    watermark: 1,
  }
  let model = {
    ..test_model()
    .with_archive_override(
      @interop.ChannelId::Local,
      {
        session: "desktop-old",
        workspace: @interop.ChannelId::Local.test_project(),
      },
      ArchiveStored,
    )
    .with_dev(dev => { ..dev, archived: [item], })
    .replace_conversation(archived),
    active_session: item.id,
  }
  let (_, ready) = update_dev(dispatch, BridgeReady, model)
  inspect(ready.dev().connection_generation, content="1")
  inspect(ready.dev().archive_overrides.length(), content="0")
  let (_, live) = update_dev(
    dispatch,
    SessionsLoaded([item], connection_generation=1, request_generation=1),
    ready,
  )
  guard live.find_conversation(@interop.ChannelId::Local, item.id)
    is Some(restored) else {
    fail("the freshly live record disappeared during reconnect")
  }
  assert_true(restored.record is LiveRecord)
  assert_true(
    live
    .dev()
    .archive_override({ session: item.id, workspace: item.workspace, })
    is Some(ArchiveLive),
  )
  guard restored.sync is Reloading(generation=2, ..) else {
    fail("fresh live-list truth did not fence the archived reload")
  }
  let (_, stale_archived) = update_dev(
    dispatch,
    SessionRefreshed(
      goal=None,
      goal_markers=[],
      prediction=None,
      session=item.id,
      items=[
        {
          kind: Assistant(
            reasoning=None,
            prose=Some("late archived answer"),
            calls=[],
            replay=false,
            finished=false,
          ),
          ts: None,
          sequence: Some(1),
        },
      ],
      watermark=1,
      generation=1,
    ),
    live,
  )
  assert_true(stale_archived.active().record is LiveRecord)
  assert_eq(
    stale_archived.active().messages[0].text(),
    Some("cached archived answer"),
  )
  let (_, live_again) = update_dev(
    dispatch,
    SessionsLoaded([item], connection_generation=1, request_generation=1),
    ready,
  )
  guard live_again.find_conversation(@interop.ChannelId::Local, item.id)
    is Some(restored_again) else {
    fail("the repeated live-list update dropped the restored record")
  }
  assert_true(restored_again.record is LiveRecord)
  guard restored_again.sync is Reloading(generation=2, ..) else {
    fail("the reconnect transition was not idempotent")
  }
  let (_, reconciled) = update_dev(
    dispatch,
    ArchivedLoaded(
      [],
      connection_generation=1,
      request_generation=1,
      fresh_session="desktop-unused",
    ),
    stale_archived,
  )
  assert_true(reconciled.dev().sessions.any(current => current.id == item.id))
  inspect(reconciled.dev().archived.length(), content="0")
  let (_, stale) = update_dev(
    dispatch,
    ArchivedLoaded(
      [item],
      connection_generation=0,
      request_generation=1,
      fresh_session="desktop-stale",
    ),
    reconciled,
  )
  inspect(stale.dev().archived.length(), content="0")
}

///|
test "an older same-connection live list cannot replace a newer reply" {
  let dispatch = test_dispatch()
  let old : @transcript.SessionListItem = {
    id: "desktop-listed",
    title: Some("old title"),
    workspace: @interop.ChannelId::Local.test_project(),
    workspace_name: "",
    updated_at_ms: None,
  }
  let current = { ..old, title: Some("current title"), }
  let model = test_model().with_dev(dev => {
    ..dev,
    sessions_request_generation: 2,
  })
  let (_, newest) = update_dev(
    dispatch,
    SessionsLoaded([current], connection_generation=0, request_generation=2),
    model,
  )
  let (_, stale) = update_dev(
    dispatch,
    SessionsLoaded([old], connection_generation=0, request_generation=1),
    newest,
  )
  inspect(stale.dev().sessions.length(), content="1")
  assert_true(stale.dev().sessions[0].title is Some("current title"))
}

///|
test "an older same-connection archived list cannot replace a newer reply" {
  let dispatch = test_dispatch()
  let old : @transcript.SessionListItem = {
    id: "desktop-archived",
    title: Some("old title"),
    workspace: @interop.ChannelId::Local.test_project(),
    workspace_name: "",
    updated_at_ms: None,
  }
  let current = { ..old, title: Some("current title"), }
  let model = test_model().with_dev(dev => {
    ..dev,
    archived_request_generation: 2,
  })
  let (_, newest) = update_dev(
    dispatch,
    ArchivedLoaded(
      [current],
      connection_generation=0,
      request_generation=2,
      fresh_session="desktop-unused",
    ),
    model,
  )
  let (_, stale) = update_dev(
    dispatch,
    ArchivedLoaded(
      [old],
      connection_generation=0,
      request_generation=1,
      fresh_session="desktop-unused",
    ),
    newest,
  )
  inspect(stale.dev().archived.length(), content="1")
  assert_true(stale.dev().archived[0].title is Some("current title"))
}

///|
test "an archived background session drops its live state, active stays" {
  let dispatch = test_dispatch()
  let model = {
    ..test_model(),
    conversations: [
      test_conversation(),
      empty_conversation(
        @interop.ChannelId::Local,
        "desktop-old",
        @interop.ChannelId::Local.test_project(),
      ),
    ],
  }
  let (_, next) = update(
    dispatch,
    archived_loaded([archived_item("desktop-old")]),
    model,
  )
  inspect(next.dev().archived.length(), content="1")
  inspect(next.dev().archived[0].id, content="desktop-old")
  assert_true(
    next.find_conversation(@interop.ChannelId::Local, "desktop-old") is None,
  )
  inspect(next.active_session, content="desktop-test")
}

///|
test "an archived-list reply immediately replaces the active conversation" {
  let dispatch = test_dispatch()
  let (_, next) = update(
    dispatch,
    archived_loaded([placed_archived_item("desktop-test")]),
    test_model(),
  )
  assert_true(
    next.find_conversation(@interop.ChannelId::Local, "desktop-test") is None,
  )
  inspect(next.active_session, content="desktop-archive-replacement")
  inspect(next.dev().archived[0].id, content="desktop-test")
}
