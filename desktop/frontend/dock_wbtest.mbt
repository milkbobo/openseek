///|
test "terminal visibility changes in the root-owned terminal state" {
  let dispatch = test_dispatch()
  let model = test_model()
  assert_false(model.terminal.is_open())
  let (_, opened) = update(dispatch, Terminal(@terminal.ToggleTerminal), model)
  assert_true(opened.terminal.is_open())
  let (_, closed) = update(dispatch, Terminal(@terminal.ToggleTerminal), opened)
  assert_false(closed.terminal.is_open())
}

///|
test "launcher rows open Browser and all Explorer destinations" {
  let dispatch = test_dispatch()
  let model = desktop_model()
  let (_, model) = update(dispatch, ToggleRightPanel, model)
  let (_, model) = update(dispatch, ToggleRightPanelMenu, model)
  assert_true(model.right_panel_menu_open)
  let (_, model) = update(dispatch, BrowserTabRequested, model)
  assert_false(model.right_panel_menu_open)
  assert_true(@dock.active_browser(model.dock) == Some(1))
  let page = @preview.page(model.preview, 1).unwrap()
  assert_true(page.url is None)
  assert_false(page.loading)
  let (_, model) = update(dispatch, ExplorerRequested(ExplorerFiles), model)
  assert_true(model.dock.active == Some(@dock.DockTab::FilePicker))
  assert_true(model.file_panel.explorer_mode is ExplorerFiles)
  assert_true(
    model.dock.tabs == [@dock.DockTab::Browser(id=1), @dock.DockTab::FilePicker],
  )
  let (_, model) = update(dispatch, ExplorerRequested(ExplorerChanges), model)
  assert_true(model.dock.active == Some(@dock.DockTab::FilePicker))
  assert_true(model.file_panel.explorer_mode is ExplorerChanges)
  assert_true(model.file_panel.changes is ChangeListLoading(_))
  // Files is an explicit destination even after Review selected Changes.
  let (_, model) = update(dispatch, ExplorerRequested(ExplorerFiles), model)
  assert_true(model.file_panel.explorer_mode is ExplorerFiles)
  let (_, model) = update(dispatch, ExplorerRequested(ExplorerSearch), model)
  assert_true(model.file_panel.explorer_mode is ExplorerSearch)
  assert_true(model.file_panel.tree_open)
}

///|
test "CloseDockTabs All keeps the empty launcher at the chosen panel size" {
  let dispatch = test_dispatch()
  let (_, browser) = update(dispatch, BrowserTabRequested, {
    ..desktop_model(),
    right_panel_open: true,
  })
  let (_, mixed) = update(dispatch, ExplorerRequested(ExplorerFiles), browser)
  let mixed = {
    ..mixed,
    right_panel_menu_open: true,
    right_panel_expanded: true,
  }
  assert_true(
    mixed.dock.tabs == [@dock.DockTab::Browser(id=1), @dock.DockTab::FilePicker],
  )
  let (_, closed) = update(dispatch, CloseDockTabs(All), mixed)
  assert_true(closed.dock.tabs.is_empty())
  assert_true(closed.dock.active is None)
  assert_true(@preview.page(closed.preview, 1) is None)
  assert_true(closed.right_panel_open)
  assert_false(closed.right_panel_menu_open)
  assert_true(closed.right_panel_expanded)
  let (_, normal) = update(dispatch, CloseDockTabs(All), {
    ..mixed,
    right_panel_expanded: false,
  })
  assert_true(normal.right_panel_open)
  assert_false(normal.right_panel_expanded)
}

///|
test "relative tab close preserves survivors and tears down only selected pages" {
  let dispatch = test_dispatch()
  let (_, first) = update(dispatch, BrowserTabRequested, desktop_model())
  let (_, picker) = update(dispatch, ExplorerRequested(ExplorerFiles), first)
  let (_, second) = update(dispatch, BrowserTabRequested, picker)
  let mixed = { ..second, right_panel_expanded: true, }
  let (_, left) = update(dispatch, CloseDockTabs(ToLeft(FilePicker)), mixed)
  assert_true(
    left.dock.tabs == [@dock.DockTab::FilePicker, @dock.DockTab::Browser(id=2)],
  )
  assert_true(left.dock.active == Some(@dock.DockTab::Browser(id=2)))
  assert_true(@preview.page(left.preview, 1) is None)
  assert_true(@preview.page(left.preview, 2) is Some(_))
  assert_true(left.right_panel_expanded)
  let (_, right) = update(dispatch, CloseDockTabs(ToRight(FilePicker)), mixed)
  assert_true(
    right.dock.tabs == [@dock.DockTab::Browser(id=1), @dock.DockTab::FilePicker],
  )
  assert_true(right.dock.active == Some(@dock.DockTab::FilePicker))
  assert_true(@preview.page(right.preview, 1) is Some(_))
  assert_true(@preview.page(right.preview, 2) is None)
  let (_, others) = update(dispatch, CloseDockTabs(Others(FilePicker)), mixed)
  assert_true(others.dock.tabs == [@dock.DockTab::FilePicker])
  assert_true(others.dock.active == Some(@dock.DockTab::FilePicker))
  assert_true(@preview.page(others.preview, 1) is None)
  assert_true(@preview.page(others.preview, 2) is None)
  assert_true(others.right_panel_open)
  assert_true(others.right_panel_expanded)
}
