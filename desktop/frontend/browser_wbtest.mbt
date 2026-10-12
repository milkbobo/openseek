///|
test "opening an external link is a pure model transition" {
  let dispatch = test_dispatch()
  let base = test_model()
  let (_, first) = update(
    dispatch,
    ExternalLinkClicked("https://example.com/docs"),
    base,
  )
  let (_, second) = update(
    dispatch,
    ExternalLinkClicked("https://example.com/docs"),
    base,
  )
  inspect(first.active_session, content="desktop-test")
  inspect(second.active_session, content="desktop-test")
  inspect(first.notifications.length(), content="0")
  inspect(second.notifications.length(), content="0")
}

///|
test "web links open (and reuse) a dock browser tab; other schemes do not" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let generation = model.file_panel.file_link_generation
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  assert_true(model.right_panel_open)
  assert_eq(model.file_panel.file_link_generation, generation + 1)
  assert_true(@dock.active_browser(model.dock) == Some(1))
  assert_true(
    @preview.page(model.preview, 1).unwrap().url ==
    Some("http://127.0.0.1:5173/"),
  )
  // The terminal component forwards its semantic link action to this same
  // application policy; exercise the policy directly here.
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("https://terminal.example/docs"),
    model,
  )
  assert_eq(model.dock.tabs.length(), 2)
  assert_eq(model.file_panel.file_link_generation, generation + 2)
  assert_true(@dock.active_browser(model.dock) == Some(2))
  assert_true(
    @preview.page(model.preview, 2).unwrap().url ==
    Some("https://terminal.example/docs"),
  )
  // The same URL re-activates the existing tab instead of duplicating, and
  // the reuse re-navigates so the view cannot keep showing a stale page.
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  assert_eq(model.dock.tabs.length(), 2)
  assert_eq(model.preview.pages.length(), 2)
  assert_true(@dock.active_browser(model.dock) == Some(1))
  assert_true(
    @preview.page(model.preview, 1).unwrap().url ==
    Some("http://127.0.0.1:5173/"),
  )
  assert_true(@preview.page(model.preview, 1).unwrap().loading)
  assert_eq(model.file_panel.file_link_generation, generation + 3)
  // External sites are web pages too: they get their own tab.
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("https://github.com/moonbit"),
    model,
  )
  assert_eq(model.dock.tabs.length(), 3)
  assert_true(@dock.active_browser(model.dock) == Some(3))
  assert_eq(model.file_panel.file_link_generation, generation + 4)
  // A non-web scheme keeps the system handler: no tab appears.
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("mailto:someone@example.com"),
    model,
  )
  assert_eq(model.dock.tabs.length(), 3)
  assert_eq(model.file_panel.file_link_generation, generation + 4)
  // So does a link clicked on another screen, where the dock is not on
  // screen to show a tab — Settings' device-page link wants the browser the
  // user is signed in to anyway.
  let (_, settings) = update(
    dispatch,
    ExternalLinkClicked("https://openseek.test/d/abc"),
    { ..model, screen: Settings, },
  )
  assert_eq(settings.dock.tabs.length(), 3)
  assert_eq(settings.preview.pages.length(), 3)
  assert_eq(settings.file_panel.file_link_generation, generation + 4)
}

///|
test "Codex web links use the same dock browser route as OpenSeek" {
  let dispatch = test_dispatch()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-1",
      "preview": "Open its pull request",
      "cwd": "/work/codex-project",
      "turns": [],
    },
  })
  // Exercise the same root transition as a sidebar click. It selects the
  // Codex screen and, before a later PR click can arrive, reconciles the live
  // dock strip from the OpenSeek conversation owner to this Codex task.
  let (_, model) = update(dispatch, CodexOpenThread("codex-thread-1"), {
    ..desktop_model(),
    codex,
  })
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("https://github.com/moonbit-community/pty/pull/18"),
    model,
  )
  assert_true(model.right_panel_open)
  assert_true(@dock.active_browser(model.dock) == Some(1))
  assert_true(
    @preview.page(model.preview, 1).unwrap().url ==
    Some("https://github.com/moonbit-community/pty/pull/18"),
  )
}

///|
test "same-URL reuse scans this strip, not the global page map" {
  let dispatch = test_dispatch()
  let url = "http://127.0.0.1:5173/"
  // Another conversation's parked strip already holds this URL: its page
  // sits in the global map with no tab in this strip. It must not shadow
  // this strip's own tab.
  let (foreign, _) = @preview.open_page(@preview.State::empty(), url~)
  let model = { ..desktop_model(), preview: foreign, }
  let (_, model) = update(dispatch, ExternalLinkClicked(url), model)
  assert_eq(model.dock.tabs.length(), 1)
  assert_eq(model.preview.pages.length(), 2)
  // A repeat click re-activates this strip's tab instead of stacking a
  // duplicate per click.
  let (_, model) = update(dispatch, ExternalLinkClicked(url), model)
  assert_eq(model.dock.tabs.length(), 1)
  assert_eq(model.preview.pages.length(), 2)
}

///|
test "a remote console routes loopback links to the system browser too" {
  let dispatch = test_dispatch()
  // test_model is desktop-shaped except for the flag; without native views
  // the dock must not grow browser tabs.
  let model = test_model()
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  assert_true(model.dock.tabs.is_empty())
  assert_true(model.preview.pages.is_empty())
}

///|
test "re-clicking a chat link re-navigates the reused tab to the clicked URL" {
  // The reuse matched the page's optimistic URL mirror, which can have
  // drifted from what the native view shows — the clicked link must win over
  // whatever the tab currently displays, and the stale pane placement must
  // not survive a possibly rebuilt view (#1021).
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  let rect : @preview.Rect = { x: 480, y: 46, width: 640, height: 700, }
  let (_, model) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(model.browser_pane.shown == Some(1))
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("https://github.com/moonbit"),
    model,
  )
  assert_true(@dock.active_browser(model.dock) == Some(2))
  // Back to the first link: its tab re-activates AND re-navigates.
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  assert_eq(model.dock.tabs.length(), 2)
  assert_true(@dock.active_browser(model.dock) == Some(1))
  let page = @preview.page(model.preview, 1).unwrap()
  assert_true(page.url == Some("http://127.0.0.1:5173/"))
  assert_eq(page.input, "http://127.0.0.1:5173/")
  assert_true(page.loading)
  assert_true(page.failure is None)
  // A rebuilt view arrives hidden at a placeholder size, so the placement
  // the old view had is dropped for the next sync to re-measure.
  assert_true(model.browser_pane.shown is None)
  assert_true(model.browser_pane.rect is None)
  // …and the re-measure places the view again.
  let (_, model) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(model.browser_pane.shown == Some(1))
  assert_true(model.browser_pane.rect == Some(rect))
}

///|
test "submitting the address bar normalizes the draft and commits it" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(dispatch, ToggleRightPanel, model)
  let (_, model) = update(dispatch, BrowserTabRequested, model)
  let (_, model) = update(
    dispatch,
    BrowserAddressEdited("localhost:5173"),
    model,
  )
  let generation = model.file_panel.file_link_generation
  let (_, model) = update(dispatch, BrowserNavigateSubmitted, model)
  let page = @preview.page(model.preview, 1).unwrap()
  assert_true(page.url == Some("http://localhost:5173"))
  assert_eq(page.input, "http://localhost:5173")
  assert_true(page.loading)
  assert_eq(model.file_panel.file_link_generation, generation + 1)
  // A non-navigable draft changes nothing — including a bare scheme, which
  // the host would reject after the URL had already been committed.
  let (_, edited) = update(dispatch, BrowserAddressEdited("two words"), model)
  let (_, unchanged) = update(dispatch, BrowserNavigateSubmitted, edited)
  assert_true(
    @preview.page(unchanged.preview, 1).unwrap().url ==
    Some("http://localhost:5173"),
  )
  assert_eq(
    unchanged.file_panel.file_link_generation,
    model.file_panel.file_link_generation,
  )
  let (_, edited) = update(dispatch, BrowserAddressEdited("http://"), unchanged)
  let (_, still) = update(dispatch, BrowserNavigateSubmitted, edited)
  assert_true(
    @preview.page(still.preview, 1).unwrap().url ==
    Some("http://localhost:5173"),
  )
  assert_eq(
    still.file_panel.file_link_generation,
    model.file_panel.file_link_generation,
  )
}

///|
test "navigating an already-placed tab re-places its view" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  let rect : @preview.Rect = { x: 480, y: 46, width: 640, height: 700, }
  let (_, model) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(model.browser_pane.shown == Some(1))
  // The host may have rebuilt the view under `browser.navigate` (nothing
  // acknowledges the ops that placed the old one), and a rebuilt view is
  // hidden at a placeholder size. Keeping the placement would leave the tab
  // blank until an unrelated resize, so the submission drops it…
  let (_, edited) = update(
    dispatch,
    BrowserAddressEdited("https://github.com/moonbit"),
    model,
  )
  let (_, navigated) = update(dispatch, BrowserNavigateSubmitted, edited)
  assert_true(navigated.browser_pane.shown is None)
  assert_true(navigated.browser_pane.rect is None)
  // …and the re-measure it provokes places the view again.
  let (_, replaced) = update(dispatch, BrowserPaneMeasured(rect~), navigated)
  assert_true(replaced.browser_pane.shown == Some(1))
  assert_true(replaced.browser_pane.rect == Some(rect))
}

///|
test "pane measurements place the active view and idempotently settle" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  let rect : @preview.Rect = { x: 480, y: 46, width: 640, height: 700, }
  let (_, model) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(model.browser_pane.shown == Some(1))
  assert_true(model.browser_pane.rect == Some(rect))
  let (_, again) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(again == model)
  // A zero-size measurement (the observer firing against a hidden pane)
  // never places the view.
  let zero : @preview.Rect = { x: 0, y: 0, width: 0, height: 0, }
  let (_, still) = update(dispatch, BrowserPaneMeasured(rect=zero), model)
  assert_true(still.browser_pane.rect == Some(rect))
}

///|
test "the launcher popup and final tab close both retire the shown view" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  let rect : @preview.Rect = { x: 480, y: 46, width: 640, height: 700, }
  let (_, model) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(model.browser_pane.shown == Some(1))
  // The popup overlaps the pane, so the native view must hide under it.
  let (_, covered) = update(dispatch, ToggleRightPanelMenu, model)
  assert_true(covered.browser_pane.shown is None)
  // Closing the tab drops the page and the placement.
  let closing = { ..model, right_panel_expanded: true, }
  let (_, closed) = update(
    dispatch,
    Dock(TabClosed(@dock.DockTab::Browser(id=1))),
    closing,
  )
  let (_, closed_again) = update(
    dispatch,
    Dock(TabClosed(@dock.DockTab::Browser(id=1))),
    closing,
  )
  assert_true(closed_again == closed)
  assert_true(closed.browser_pane.shown is None)
  assert_true(@preview.page(closed.preview, 1) is None)
  assert_true(closed.dock.tabs.is_empty())
  assert_false(closed.right_panel_open)
  assert_false(closed.right_panel_menu_open)
  assert_false(closed.right_panel_expanded)
}

///|
test "closing a background Browser tab keeps the shown view placement" {
  let dispatch = test_dispatch()
  let (_, first) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/one"),
    desktop_model(),
  )
  let (_, second) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/two"),
    first,
  )
  let rect : @preview.Rect = { x: 480, y: 46, width: 640, height: 700, }
  let (_, shown) = update(dispatch, BrowserPaneMeasured(rect~), second)
  assert_true(shown.browser_pane.shown == Some(2))
  let (_, closed) = update(
    dispatch,
    Dock(TabClosed(@dock.DockTab::Browser(id=1))),
    shown,
  )
  assert_true(closed.browser_pane.shown == Some(2))
  assert_true(closed.browser_pane.rect == Some(rect))
  assert_true(@preview.page(closed.preview, 1) is None)
  assert_true(@preview.page(closed.preview, 2) is Some(_))
  assert_true(closed.right_panel_open)
}

///|
test "full-screen modals hide the native view and closing restores it" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(
    dispatch,
    ExternalLinkClicked("http://127.0.0.1:5173/"),
    model,
  )
  let rect : @preview.Rect = { x: 480, y: 46, width: 640, height: 700, }
  let (_, model) = update(dispatch, BrowserPaneMeasured(rect~), model)
  assert_true(model.browser_pane.shown == Some(1))
  // The workspace picker's modal covers the pane; native views z-order
  // above HTML, so the view must hide first.
  let (_, covered) = update(dispatch, PickProject(Local), model)
  assert_true(covered.project_picker is Some(_))
  assert_true(covered.browser_pane.shown is None)
  // Closing the modal re-measures; the next measurement re-places the view.
  let (_, closed) = update(
    dispatch,
    ProjectPicker(@project_picker.Msg::Close),
    covered,
  )
  let (_, restored) = update(dispatch, BrowserPaneMeasured(rect~), closed)
  assert_true(restored.browser_pane.shown == Some(1))
  // Setup API owns the whole screen too. The browser is a native view above
  // the HTML shell, so opening the modal must hide it; dismissing the modal
  // then re-measures and restores the active Browser tab.
  let (_, setup) = update(
    dispatch,
    HostSettings(ProviderChanged("custom")),
    restored,
  )
  assert_true(setup.host_settings.api_setup_open)
  assert_true(setup.browser_pane.shown is None)
  let (_, setup_closed) = update(dispatch, HostSettings(DismissApiSetup), setup)
  assert_false(setup_closed.host_settings.api_setup_open)
  let (_, setup_restored) = update(
    dispatch,
    BrowserPaneMeasured(rect~),
    setup_closed,
  )
  assert_true(setup_restored.browser_pane.shown == Some(1))
  // The composer's git popover opens upward over the pane's bottom-left
  // corner, so a native view left showing would paint straight over it. The
  // popover needs a branch to have a trigger at all, so give the
  // conversation one before opening it.
  let (_, on_branch) = update_dev(dispatch, branch_reply("feature/x"), restored)
  let (_, detailing) = update(dispatch, ToggleGitDetails, on_branch)
  assert_true(detailing.browser_pane.shown is None)
  // So do the other two surfaces `view.mbt` appends beside the picker: the
  // archive-discard confirmation and Quick Open.
  let (_, archiving) = update_dev(
    dispatch,
    ArchiveNeedsForce(session="desktop-test", refusal={
      worktree: "wt-1",
      dirty_paths: ["desktop/lepus"],
      dirty_path_count: 1,
    }),
    restored,
  )
  assert_true(archiving.archive_confirm is Some(_))
  assert_true(archiving.browser_pane.shown is None)
  let (_, searching) = update(
    dispatch,
    QuickOpenOpen(@quick_open.Symbols),
    restored,
  )
  assert_true(searching.quick_open.is_open())
  assert_true(searching.browser_pane.shown is None)
}
