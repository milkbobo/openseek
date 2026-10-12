///|
test "a finish the user watched leaves no unseen dot" {
  let dispatch = test_dispatch()
  let (_, next) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    running_model(),
  )
  inspect(next.active().unseen_finish, content="false")
}

///|
test "a finish in an unfocused window still needs attention" {
  let dispatch = test_dispatch()
  let model = { ..running_model(), window_focused: false, }
  let (_, next) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    model,
  )
  inspect(next.active().unseen_finish, content="true")
  inspect(next.notification_badge_count(), content="1")
  let (_, focused) = update(dispatch, WindowFocusChanged(true), next)
  inspect(focused.active().unseen_finish, content="false")
  inspect(focused.notification_badge_count(), content="0")
}

///|
test "a finish behind settings stays unread until the chat is reopened" {
  let dispatch = test_dispatch()
  let model = { ..running_model(), screen: Settings, }
  let (_, next) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    model,
  )
  inspect(next.active().unseen_finish, content="true")
  inspect(next.notification_badge_count(), content="1")
  let (_, opened) = open_session_on(
    dispatch,
    @interop.ChannelId::Local,
    next,
    "desktop-test",
  )
  assert_true(opened.screen is Chat)
  inspect(opened.active().unseen_finish, content="false")
  inspect(opened.notification_badge_count(), content="0")
}

///|
test "a background finish marks its conversation until it is opened" {
  let dispatch = test_dispatch()
  // The run belongs to "desktop-test"; the user is looking at another chat.
  let model = { ..running_model(), active_session: "desktop-elsewhere", }
  let (_, next) = update_dev(
    dispatch,
    Finished(run_id="r7", status="finished", answer=Some("done")),
    model,
  )
  guard next.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(conv) else {
    fail("conversation missing")
  }
  inspect(conv.unseen_finish, content="true")
  let opened = next.activate(
    @interop.ChannelId::Local,
    "desktop-test",
    @interop.ChannelId::Local.test_project(),
  )
  guard opened.find_conversation(@interop.ChannelId::Local, "desktop-test")
    is Some(seen) else {
    fail("conversation missing after activate")
  }
  inspect(seen.unseen_finish, content="false")
}
