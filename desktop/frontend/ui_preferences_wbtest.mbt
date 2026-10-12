///|
test "loaded UI preferences parse their wire names" {
  let dispatch = test_dispatch()
  let (_, restored) = update(
    dispatch,
    SettingsLoaded(
      notification_corner=Some("top-left"),
      tree_layout=None,
      theme=Some("dark"),
      font_size=Some("15"),
      fps_overlay_enabled=true,
      minimal_transcript=false,
      model=Some("deepseek-v4-flash"),
      conversation_models=Some(
        "[{\"key\":\"local/desktop-test\",\"model\":\"deepseek-v4-pro\"}]",
      ),
      agent=Some("codex"),
      codex_model=Some("gpt-5.4-codex"),
      codex_effort=Some("xhigh"),
      openseek_effort=Some("high"),
      glm_effort=Some("max"),
    ),
    test_model(),
  )
  assert_true(restored.notification_corner is TopLeft)
  assert_true(restored.theme is Dark)
  assert_eq(restored.app_font_size, AppFontSize(15))
  assert_true(restored.default_model is DsFlash)
  assert_true(restored.default_agent is CodexAgent)
  assert_true(restored.openseek_reasoning is ReasoningHigh)
  assert_true(restored.glm_reasoning is ReasoningMax)
  // The stored conversation outranks the stored default for its own chat.
  assert_true(restored.active().engine_model is DsPro)
  // Unknown stored values fall back to the defaults.
  let (_, unknown) = update(
    dispatch,
    SettingsLoaded(
      notification_corner=None,
      tree_layout=None,
      theme=Some("broken"),
      font_size=Some("broken"),
      fps_overlay_enabled=false,
      minimal_transcript=false,
      model=None,
      conversation_models=Some("not json"),
      agent=Some("broken"),
      codex_model=None,
      codex_effort=None,
      openseek_effort=Some("broken"),
      glm_effort=Some("broken"),
    ),
    test_model(),
  )
  assert_true(unknown.notification_corner is BottomRight)
  assert_true(unknown.theme is System)
  assert_eq(unknown.app_font_size, AppFontSize(14))
  assert_true(unknown.default_model is DsFlash)
  assert_true(unknown.openseek_reasoning is ReasoningHigh)
  assert_true(unknown.glm_reasoning is ReasoningOff)
  assert_true(unknown.default_agent is OpenSeekAgent)
  // A store that will not parse remembers nothing rather than wedging.
  assert_eq(unknown.conversation_models.length(), 0)
}

///|
test "the notification-corner setting parses its wire names" {
  let dispatch = test_dispatch()
  let (_, moved) = update(
    dispatch,
    NotificationCornerChanged("top-right"),
    test_model(),
  )
  assert_true(moved.notification_corner is TopRight)
  let (_, unknown) = update(
    dispatch,
    NotificationCornerChanged("nowhere"),
    moved,
  )
  assert_true(unknown.notification_corner is BottomRight)
}

///|
test "the tree-layout setting parses its wire names" {
  let dispatch = test_dispatch()
  let (_, docked) = update(
    dispatch,
    TreeLayoutChanged("bottom-panel"),
    test_model(),
  )
  assert_true(docked.tree_layout is BottomPanel)
  // An unknown stored value falls back to the default right sidebar.
  let (_, unknown) = update(dispatch, TreeLayoutChanged("floating"), docked)
  assert_true(unknown.tree_layout is RightSidebar)
}

///|
test "the color-scheme watcher only changes a system-following theme" {
  let dispatch = test_dispatch()
  let system = { ..test_model(), theme: System, system_dark: false, }
  let (_, dark) = update(dispatch, ColorSchemeChanged(true), system)
  assert_true(dark.theme is System)
  assert_true(dark.system_dark)
  let fixed = { ..dark, theme: Light, }
  let (_, changed_host) = update(dispatch, ColorSchemeChanged(false), fixed)
  assert_true(changed_host.theme is Light)
  assert_false(changed_host.system_dark)
}

///|
test "theme settings switch fixed palettes and are idempotent" {
  let dispatch = test_dispatch()
  let system = { ..test_model(), theme: System, system_dark: true, }
  let (_, first) = update(dispatch, ThemeChanged("dark"), system)
  let (_, repeated) = update(dispatch, ThemeChanged("dark"), first)
  assert_true(first.theme is Dark)
  assert_true(repeated.theme is Dark)
  assert_true(first.system_dark && repeated.system_dark)
  let (_, following) = update(dispatch, ThemeChanged("system"), first)
  assert_true(following.theme is System)
  assert_true(following.system_dark)
  let (_, light) = update(dispatch, ThemeChanged("light"), first)
  assert_true(light.theme is Light)
  let (_, unchanged) = update(dispatch, ThemeChanged("unknown"), system)
  assert_true(unchanged.theme is System)
}

///|
test "font-size settings switch every text surface and are idempotent" {
  assert_eq(AppFontSize(12).pixels(), 11.0)
  assert_eq(AppFontSize(14).pixels(), 13.0)
  assert_eq(AppFontSize(18).pixels(), 17.0)
  let dispatch = test_dispatch()
  let model = test_model()
  let (_, first) = update(dispatch, FontSizeChanged("15"), model)
  let (_, second) = update(dispatch, FontSizeChanged("15"), first)
  assert_eq(first.app_font_size, AppFontSize(15))
  assert_eq(second.app_font_size, AppFontSize(15))
  assert_eq(first.app_font_size.pixels(), 14.0)
  let (_, largest) = update(dispatch, FontSizeChanged("18"), first)
  assert_eq(largest.app_font_size, AppFontSize(18))
  assert_eq(largest.app_font_size.pixels(), 17.0)
  let (_, unchanged) = update(dispatch, FontSizeChanged("unknown"), model)
  assert_eq(unchanged.app_font_size, AppFontSize(14))
}
