// A side chat beside the fixture conversation: its tab follows its record,
// it never takes a sidebar row, and what its composer does in the dock lands
// on it and never on the conversation in the column.

///|
const SideChatId : String = "desktop-test-sc-0a1b2c3d"

///|
fn side_chat_owner() -> @interop.ConversationKey {
  { channel: @interop.ChannelId::Local, session: SideChatId, }
}

///|
/// The fixture conversation in the column, its side chat listed and running
/// with a question waiting, and the dock open. One message through `update`
/// lets the post-dispatch sync give the strip its tab.
fn side_chat_model() -> Model raise {
  let side = fold_engine(
    {
      ..empty_conversation(
        @interop.ChannelId::Local,
        SideChatId,
        @interop.ChannelId::Local.test_project(),
      ),
      run: Open(run_id="r7", stage=Opened),
    },
    ApprovalRequested(
      id="ap-side",
      tool_name="mbtx",
      detail="escalate",
      body=None,
    ),
  )
  let model = {
    ..test_model().with_listed(["desktop-test", SideChatId]),
    right_panel_open: true,
    window_focused: true,
  }.replace_conversation(side)
  let (_, synced) = update(test_dispatch(), CloseSelectMenu, model)
  synced
}

///|
fn side_chat_identity(model : Model) -> @composer.Identity {
  {
    owner: @interop.Host(side_chat_owner()),
    archive_generation: model.composer_entry_retirements.length(),
  }
}

///|
test "a listed side chat is a tab in its conversation's dock" {
  let model = side_chat_model()
  assert_true(model.dock.tabs == [SideChat(owner=side_chat_owner())])
  assert_true(model.mounted_side_chat_owner() == Some(side_chat_owner()))
  assert_true(
    model.side_chats_of({
      channel: @interop.ChannelId::Local,
      session: "desktop-test",
    }) ==
    [side_chat_owner()],
  )
  // Its finish is watched there.
  assert_true(
    model.conversation_is_visible(@interop.ChannelId::Local, SideChatId),
  )
  // The record going away takes the tab along.
  let (_, gone) = update(
    test_dispatch(),
    CloseSelectMenu,
    model.with_listed(["desktop-test"]),
  )
  assert_true(gone.dock.tabs.is_empty())
  assert_true(gone.mounted_side_chat_owner() is None)
}

///|
test "a side chat never takes a sidebar row" {
  let model = side_chat_model()
  guard model.focused_device() is Some(dev) else { fail("no device") }
  let rows : Array[(RowStamp, @conversation.Input)] = []
  model.push_group_component_inputs(
    rows,
    dev,
    @interop.ChannelId::Local.test_project(),
    listed=id => id == "desktop-test" || id == SideChatId,
    archived=_ => false,
  )
  assert_true(rows.any(row => row.1.id().conversation() == "desktop-test"))
  assert_false(
    rows.any(row => {
      row.1.id().conversation() == SideChatId ||
      row.1.children.any(child => child.id().conversation() == SideChatId)
    }),
  )
}

///|
test "an approval answered in the dock settles the side chat's question" {
  let model = side_chat_model()
  let (_, answered) = update(
    test_dispatch(),
    ComposerAction(
      @composer.ApprovalAnswered(identity=side_chat_identity(model), allow=true),
    ),
    model,
  )
  guard answered.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(side) &&
    side.pending_approval is Some(pending) else {
    fail("the side chat's question must still be held")
  }
  assert_true(pending.answered)
  // The column is where it was, and its conversation is untouched.
  assert_eq(answered.active_session, "desktop-test")
  assert_true(answered.active().pending_approval is None)
}

///|
test "a column control sent from the dock is dropped" {
  let model = side_chat_model()
  let (_, toggled) = update(
    test_dispatch(),
    ComposerAction(
      @composer.ModelMenuToggled(identity=side_chat_identity(model)),
    ),
    model,
  )
  assert_true(toggled.select_menu is None)
  // Nor does the side chat answer anything once its tab is not on screen.
  let hidden = { ..model, right_panel_open: false, }
  let (_, ignored) = update(
    test_dispatch(),
    ComposerAction(
      @composer.ApprovalAnswered(
        identity=side_chat_identity(hidden),
        allow=true,
      ),
    ),
    hidden,
  )
  guard ignored.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(side) &&
    side.pending_approval is Some(pending) else {
    fail("the side chat's question must still be held")
  }
  assert_false(pending.answered)
}

///|
test "switching conversations keeps the side chat's state" {
  let model = side_chat_model()
  let other = model.activate(
    @interop.ChannelId::Local,
    "desktop-other",
    @interop.ChannelId::Local.test_project(),
  )
  assert_true(
    other.find_conversation(@interop.ChannelId::Local, SideChatId) is Some(_),
  )
}

///|
test "the side chat's file completions index its conversation's checkout" {
  let model = side_chat_model()
  assert_true(model.file_panel.index is IndexEmpty)
  let (_, indexed) = update(
    test_dispatch(),
    ComposerAction(
      @composer.FileIndexEnsured(identity=side_chat_identity(model)),
    ),
    model,
  )
  assert_true(indexed.file_panel.index is IndexLoading(..))
  assert_eq(indexed.active_session, "desktop-test")
}

///|
test "the dock's composer stays with the side-chat tab while the dock is hidden" {
  let model = side_chat_model()
  let shown = model.dock_composer_input()
  assert_true(shown.identity.owner == @interop.Host(side_chat_owner()))
  // Hiding the dock keeps the composer on the side chat, so the component
  // still holds what was typed when the dock comes back.
  let hidden = { ..model, right_panel_open: false, }
  assert_true(hidden.mounted_side_chat_owner() is None)
  assert_true(
    hidden.dock_composer_input().identity.owner ==
    @interop.Host(side_chat_owner()),
  )
}

///|
/// The fixture conversation in the column with one finished turn, ending at
/// sequence 4, and nothing beside it yet.
fn side_chat_source_model() -> Model {
  test_model().replace_conversation({
    ..test_conversation(),
    sync: Synced,
    task: "",
    messages: [
      { kind: @transcript.Answer("done"), sequence: Some(4), ts: None, },
    ],
  })
}

///|
test "a side chat opens beside its conversation with the quote in its draft" {
  let model = side_chat_source_model()
  assert_true(model.can_open_side_chat())
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "desktop-test",
  }
  let (_, requested) = update(
    test_dispatch(),
    SideChatRequested(owner~, quote="the parser"),
    model,
  )
  guard requested.conversation_fork is Some(pending) &&
    pending.kind is SideChat(through=4, quote="the parser") else {
    fail("a side chat forks through the last finished turn")
  }
  // One fork at a time: the selection bar offers no second side chat.
  assert_false(requested.can_open_side_chat())
  let (_, opened) = update(
    test_dispatch(),
    ForkCompleted(
      pending,
      Ok({ session: SideChatId, title: "Title", }),
      fresh_session="desktop-unused",
    ),
    requested,
  )
  // Nothing navigates: the conversation stays in the column, and the side
  // chat is on screen in the dock with the quote waiting in its draft.
  assert_eq(opened.active_session, "desktop-test")
  assert_true(opened.right_panel_open)
  assert_true(opened.dock.active == Some(SideChat(owner=side_chat_owner())))
  assert_true(opened.mounted_side_chat_owner() == Some(side_chat_owner()))
  guard opened.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(side) else {
    fail("the side chat must be held")
  }
  assert_eq(side.task, "> the parser\n\n")
  assert_true(opened.conversation_fork is None)
}

///|
test "closing an idle side chat's tab deletes it, and a failed delete brings it back" {
  let model = side_chat_model()
  let idle = model.replace_conversation({
    ..empty_conversation(
      @interop.ChannelId::Local,
      SideChatId,
      @interop.ChannelId::Local.test_project(),
    ),
  })
  let (_, closed) = update(
    test_dispatch(),
    Dock(TabClosed(SideChat(owner=side_chat_owner()))),
    idle,
  )
  // The tab is gone at once, though the listing still has the record.
  assert_true(closed.dock.tabs.is_empty())
  assert_true(
    closed.closing_side_chats == [{ chat: side_chat_owner(), stage: Deleting, }],
  )
  let (_, failed) = update(
    test_dispatch(),
    SideChatCloseFailed(chat=side_chat_owner(), message="kept"),
    closed,
  )
  assert_true(failed.closing_side_chats.is_empty())
  assert_true(failed.dock.tabs == [SideChat(owner=side_chat_owner())])
  // A deleted record leaves the listing, and the closing entry with it.
  let (_, deleted) = update(
    test_dispatch(),
    CloseSelectMenu,
    closed.with_listed(["desktop-test"]),
  )
  assert_true(deleted.closing_side_chats.is_empty())
  assert_true(deleted.dock.tabs.is_empty())
}

///|
test "a running side chat is stopped before it is deleted" {
  let model = side_chat_model()
  let (_, closed) = update(
    test_dispatch(),
    Dock(TabClosed(SideChat(owner=side_chat_owner()))),
    model,
  )
  assert_true(
    closed.closing_side_chats == [{ chat: side_chat_owner(), stage: Stopping, }],
  )
  guard closed.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(side) else {
    fail("the side chat must be held")
  }
  assert_true(side.run is Open(stage=Cancelling, ..))
  // Its turn ends: now it is deleted.
  let (_, ended) = update(
    test_dispatch(),
    CloseSelectMenu,
    closed.replace_conversation({ ..side, run: NoRun(ended=None), }),
  )
  assert_true(
    ended.closing_side_chats == [{ chat: side_chat_owner(), stage: Deleting, }],
  )
  assert_true(ended.dock.tabs.is_empty())
}

///|
test "a side chat closed while its turn starts is stopped once the run opens" {
  let model = side_chat_model()
  guard model.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(side) else {
    fail("the side chat must be held")
  }
  let starting = model.replace_conversation({
    ..side,
    run: Starting(submission_id="s1"),
  })
  let (_, closed) = update(
    test_dispatch(),
    Dock(TabClosed(SideChat(owner=side_chat_owner()))),
    starting,
  )
  assert_true(
    closed.closing_side_chats == [{ chat: side_chat_owner(), stage: Stopping, }],
  )
  // Its run opens: now it can be, and is, stopped.
  let (_, opened) = update(
    test_dispatch(),
    CloseSelectMenu,
    closed.replace_conversation({
      ..side,
      run: Open(run_id="r9", stage=Opened),
    }),
  )
  guard opened.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(stopping) else {
    fail("the side chat must be held")
  }
  assert_true(stopping.run is Open(run_id="r9", stage=Cancelling))
  assert_true(opened.dock.tabs.is_empty())
}

///|
test "a side chat whose stop failed gets its tab back" {
  let model = side_chat_model()
  let (_, closed) = update(
    test_dispatch(),
    Dock(TabClosed(SideChat(owner=side_chat_owner()))),
    model,
  )
  assert_true(closed.dock.tabs.is_empty())
  let (_, failed) = update_dev(
    test_dispatch(),
    CancelFailed(run_id="r7", message="cancel transport failed"),
    closed,
  )
  assert_true(failed.closing_side_chats.is_empty())
  assert_true(failed.dock.tabs == [SideChat(owner=side_chat_owner())])
  guard failed.find_conversation(@interop.ChannelId::Local, SideChatId)
    is Some(side) else {
    fail("the side chat must be held")
  }
  assert_true(side.run is Open(run_id="r7", stage=AtStep(None)))
}
