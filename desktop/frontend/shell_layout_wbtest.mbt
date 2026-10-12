///|
test "viewport resize flips the narrow flag and resets the sidebar" {
  let dispatch = test_dispatch()
  let (_, narrow) = update(dispatch, ViewportResized(width=390), test_model())
  assert_true(narrow.narrow)
  assert_false(narrow.sidebar_open)
  // Same side of the breakpoint: nothing moves (idempotent).
  let (_, same) = update(dispatch, ViewportResized(width=390), narrow)
  assert_true(same.narrow)
  assert_false(same.sidebar_open)
  let (_, wide) = update(dispatch, ViewportResized(width=1280), same)
  assert_false(wide.narrow)
  assert_true(wide.sidebar_open)
}

///|
test "the narrow drawer closes when navigation lands elsewhere" {
  let dispatch = test_dispatch()
  let (_, narrow) = update(dispatch, ViewportResized(width=390), test_model())
  let (_, opened) = update(dispatch, ToggleSidebar, narrow)
  assert_true(opened.sidebar_open)
  // Navigating to the Skills page from the drawer closes it; on the wide
  // layout the same navigation leaves the sidebar column alone.
  let (_, settled) = update(dispatch, OpenSkills, opened)
  assert_false(settled.sidebar_open)
  let (_, wide) = update(dispatch, ViewportResized(width=1280), settled)
  let (_, back) = update(dispatch, HostSettings(OpenSettings), wide)
  assert_true(back.sidebar_open)
}

///|
/// The Settings page has no Done button — the sidebar is the only way out,
/// even while the endpoint is unusable (the composer blocks sending then).
test "sidebar navigation leaves the settings page" {
  let dispatch = test_dispatch()
  let model = { ..test_model(), screen: Settings, }
  let (_, next) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "s-fresh", }),
    model,
  )
  assert_true(next.screen is Chat)
}

///|
test "custom select menus switch and dismiss deterministically" {
  let dispatch = test_dispatch()
  let base = test_model()
  let (_, opened) = update(dispatch, ToggleSelectMenu(OpenSeekModelMenu), base)
  assert_true(opened.select_menu == Some(OpenSeekModelMenu))
  // The transition is pure: replaying the same message against the same
  // model produces the same open menu rather than consulting DOM state.
  let (_, replayed) = update(
    dispatch,
    ToggleSelectMenu(OpenSeekModelMenu),
    base,
  )
  assert_true(replayed.select_menu == opened.select_menu)
  let (_, switched) = update(
    dispatch,
    ToggleSelectMenu(OpenSeekReasoningMenu),
    opened,
  )
  assert_true(switched.select_menu == Some(OpenSeekReasoningMenu))
  let (_, closed) = update(dispatch, CloseSelectMenu, switched)
  assert_true(closed.select_menu is None)
  let (_, closed_again) = update(dispatch, CloseSelectMenu, closed)
  assert_true(closed_again.select_menu is None)
  // Selecting a valid row closes the popup in the same state transition that
  // applies the value; no native menu is left to close itself afterwards.
  let (_, reopened) = update(
    dispatch,
    ToggleSelectMenu(OpenSeekModelMenu),
    closed_again,
  )
  let (_, picked) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    reopened,
  )
  assert_true(picked.select_menu is None)
  let (_, reasoning_open) = update(
    dispatch,
    ToggleSelectMenu(OpenSeekReasoningMenu),
    picked,
  )
  let (_, effort_picked) = update(
    dispatch,
    OpenSeekEffortPicked("high"),
    reasoning_open,
  )
  assert_true(effort_picked.select_menu is None)
  let (_, settings_open) = update(
    dispatch,
    ToggleSelectMenu(ThemeMenu),
    effort_picked,
  )
  assert_true(settings_open.select_menu == Some(ThemeMenu))
  let (_, theme_picked) = update(dispatch, ThemeChanged("dark"), settings_open)
  assert_true(theme_picked.theme is Dark)
  assert_true(theme_picked.select_menu is None)
  let (_, open_before_switch) = update(
    dispatch,
    ToggleSelectMenu(OpenSeekModelMenu),
    theme_picked,
  )
  let (_, context_switched) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "desktop-other", }),
    open_before_switch,
  )
  assert_true(context_switched.select_menu is None)
}

///|
test "a covering overlay dismisses an open custom select" {
  let dispatch = test_dispatch()
  let base = { ..test_model(), select_menu: Some(OpenSeekModelMenu), }
  let (_, lost) = update(
    dispatch,
    FromDevice(Local, BridgeUnavailable("bridge stopped")),
    base,
  )
  assert_true(lost.bridge_state() is BridgeLost(_))
  assert_true(lost.select_menu is None)
}

///|
test "the composer's git details popover toggles shut again" {
  let dispatch = test_dispatch()
  // The popover has no trigger without a branch, so a conversation that has
  // one is where this starts — the flag cannot be raised otherwise.
  let (_, on_branch) = update_dev(
    dispatch,
    branch_reply("feature/x"),
    test_model(),
  )
  assert_false(on_branch.git_details_open)
  let (_, opened) = update(dispatch, ToggleGitDetails, on_branch)
  assert_true(opened.git_details_open)
  // Opening re-probes (the command is not inspectable here), which must not
  // disturb what is already on screen: the answer stays until its reply lands.
  assert_eq(opened.active().pull_request, on_branch.active().pull_request)
  assert_eq(opened.active().diffstat, on_branch.active().diffstat)
  let (_, closed) = update(dispatch, ToggleGitDetails, opened)
  assert_false(closed.git_details_open)
  // Switching conversations closes it, and so does the branch going away under
  // the conversation on screen. Neither produces a click for the dismissal
  // listener to see, and with no chip rendered nothing is left to click the
  // popover shut — the flag would go on hiding the native browser with no
  // visible cause.
  let (_, switched) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "desktop-other", }),
    opened,
  )
  assert_eq(switched.active_session, "desktop-other")
  assert_false(switched.git_details_open)
  let (_, lost) = update_dev(
    dispatch,
    branch_reply("", generation=opened.active().branch_generation),
    opened,
  )
  assert_false(lost.active().shows_git_chip())
  assert_false(lost.git_details_open)
  // Dismissal is idempotent where the toggle is not: the click that closes the
  // popover also reaches whatever it landed on, and a second dismissal — from
  // a page that dispatched one on its own — must not bring it back.
  let (_, dismissed) = update(dispatch, CloseGitDetails, opened)
  assert_false(dismissed.git_details_open)
  let (_, still_closed) = update(dispatch, CloseGitDetails, dismissed)
  assert_false(still_closed.git_details_open)
}

///|
test "right-panel menu closes without reopening on a second dismissal" {
  let dispatch = test_dispatch()
  // Right-panel actions update the root's single visibility state directly.
  let (_, docked) = update(dispatch, ToggleRightPanel, desktop_model())
  // The empty strip is the launcher's deliberate open state. A delayed close
  // for a tab that is already gone must not collapse that surface.
  let (_, empty) = update(
    dispatch,
    Dock(TabClosed(@dock.DockTab::FilePicker)),
    docked,
  )
  assert_true(empty.right_panel_open)
  let (_, menued) = update(dispatch, ToggleRightPanelMenu, empty)
  assert_true(menued.right_panel_menu_open)
  let (_, unmenued) = update(dispatch, CloseRightPanelMenu, menued)
  assert_false(unmenued.right_panel_menu_open)
  let (_, unmenued_twice) = update(dispatch, CloseRightPanelMenu, unmenued)
  assert_false(unmenued_twice.right_panel_menu_open)
  let (_, expanded) = update(dispatch, ToggleRightPanelExpanded, unmenued_twice)
  assert_true(expanded.right_panel_expanded)
  assert_false(expanded.right_panel_menu_open)
  let (_, restored) = update(dispatch, ToggleRightPanelExpanded, expanded)
  assert_false(restored.right_panel_expanded)
  let (_, expanded_again) = update(dispatch, ToggleRightPanelExpanded, restored)
  let (_, hidden) = update(dispatch, ToggleRightPanel, expanded_again)
  assert_false(hidden.right_panel_open)
  assert_false(hidden.right_panel_expanded)
  let (_, still_hidden) = update(dispatch, ToggleRightPanelExpanded, hidden)
  assert_true(still_hidden == hidden)
}

///|
test "right-panel menu closes when the dock owner changes" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let stale_owner : @interop.ConversationKey = {
    channel: @interop.Local,
    session: "stale-panel-owner",
  }
  let stale = {
    ..model,
    right_panel_open: true,
    right_panel_menu_open: true,
    dock: { ..model.dock, owner: Some(stale_owner), },
  }
  // Any root message runs the centralized dock synchronization. The owner
  // transition closes the menu directly, with no rendered marker or observer.
  let (_, synced) = update(dispatch, CloseGitDetails, stale)
  assert_false(synced.right_panel_menu_open)
  assert_true(synced.dock.owner != Some(stale_owner))
}

///|
test "selecting a conversation returns from the skills page to the chat" {
  let dispatch = test_dispatch()
  let (_, opened) = update(dispatch, OpenSkills, test_model())
  assert_true(opened.screen is Skills)

  // Re-selecting the active conversation is enough to switch back…
  let (_, back) = update(
    dispatch,
    OpenSession(@interop.ChannelId::Local, "desktop-test"),
    opened,
  )
  assert_true(back.screen is Chat)

  // …and so is rotating to a fresh one.
  let (_, rotated) = update(
    dispatch,
    SessionRotated({ channel: Local, session: "desktop-fresh", }),
    opened,
  )
  assert_true(rotated.screen is Chat)
}
