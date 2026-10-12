///|
test "an MCP server that failed while the engine started is reported" {
  let dispatch = test_dispatch()
  // The engine connects its MCP servers before it reads the first prompt and
  // records none of the outcome, so the stream event is the only word a user
  // gets that the tools they configured are missing.
  let (_, reported) = update_dev(
    dispatch,
    Engine(
      None,
      McpServerUnavailable(server="playwright", reason="npx: command not found"),
      session=Some("desktop-test"),
    ),
    test_model(),
  )
  guard reported.notifications.last() is Some(toast) else {
    fail("the failure should be reported")
  }
  assert_true(toast.message.contains("playwright"))
  assert_true(toast.message.has_suffix("npx: command not found"))
}

///|
test "an MCP failure stamped with a run this page has not opened yet still lands" {
  let dispatch = test_dispatch()
  // The host can stamp startup events with the id of the run it is about to
  // open, before this page has heard that the run started. The session stamp
  // is what routes them.
  let (_, reported) = update_dev(
    dispatch,
    Engine(
      Some("r-not-started-here"),
      McpConfigRejected(
        path="/home/.openseek/mcp.json",
        reason="configuration is missing an `mcpServers` object",
      ),
      session=Some("desktop-test"),
    ),
    test_model(),
  )
  guard reported.notifications.last() is Some(toast) else {
    fail("the failure should be reported")
  }
  assert_true(toast.message.contains("/home/.openseek/mcp.json"))
}

///|
test "opening Settings asks the current conversation's engine for its MCP state" {
  let dispatch = test_dispatch()
  let model = test_model()
  guard model.mcp_conversation() is Some(current) else {
    fail("the test model has a conversation on screen")
  }
  let (_, opened) = update(dispatch, OpenSetup, model)
  assert_true(opened.screen is Settings)
  assert_true(opened.mcp.phase is Checking)
  assert_true(opened.mcp.conversation == Some(current))
  // The answer is routed back into the panel.
  let (_, answered) = update(
    dispatch,
    Mcp(
      Checked(
        serial=opened.mcp.serial,
        Ok({ config_path: "/home/.openseek/mcp.json", engine: NotRunning, }),
      ),
    ),
    opened,
  )
  assert_true(answered.mcp.phase is Loaded({ engine: NotRunning, .. }))
}

///|
test "a server cut off by the MCP tool limit is reported" {
  let dispatch = test_dispatch()
  // The server connected, so nothing else marks it: without the toast the
  // tools past the limit are simply absent.
  let (_, reported) = update_dev(
    dispatch,
    Engine(
      None,
      McpToolsDropped(server="playwright", limit=100),
      session=Some("desktop-test"),
    ),
    test_model(),
  )
  guard reported.notifications.last() is Some(toast) else {
    fail("the dropped tools should be reported")
  }
  assert_true(toast.message.contains("playwright"))
  assert_true(toast.message.contains("100"))
}
