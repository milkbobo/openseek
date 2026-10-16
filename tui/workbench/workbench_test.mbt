///|
fn context() -> @workbench.Context {
  {
    session: "conversation-1",
    workspace: Some("/projects/work"),
    model: "deepseek-v4-pro",
    run_id: Some("run-1"),
    archived: false,
  }
}

///|
test "quoted Unicode paths and contents stay intact" {
  let operation = @workbench.plan("/file '目录/a file.mbt'", context())
  assert_eq(operation.command_name(), "fs.read_file")
  let payload : @protocol.ReadFilePayload = @json.from_json(operation.params())
  assert_eq(payload.path, "目录/a file.mbt")
  assert_eq(payload.root, Some("/projects/work"))
}

///|
test "key patch preserves unrelated settings and supports explicit clearing" {
  let operation = @workbench.plan("/key deepseek ''", context())
  let payload : @protocol.SettingsSetPayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.deepseek_api_key, Some(""))
  assert_eq(payload.provider, None)
  assert_eq(payload.custom_api_key, None)
  assert_eq(payload.glm_api_key, None)
}

///|
test "OpenRouter preset atomically updates provider and endpoint" {
  let operation = @workbench.plan("/provider openrouter", context())
  let payload : @protocol.SettingsSetPayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.provider, Some("custom"))
  assert_eq(
    payload.custom_api_url,
    Some("https://openrouter.ai/api/v1/chat/completions"),
  )
}

///|
test "worktree is bound to exactly the selected conversation" {
  let operation = @workbench.plan("/worktree create", context())
  let payload : @protocol.WorktreeCreatePayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.workspace, "/projects/work")
  assert_eq(payload.session, Some("conversation-1"))
  assert_eq(payload.codex_thread, None)
}

///|
test "search flags remain separate from query and generations increase" {
  let first = @workbench.plan(
    "/grep 'a b' --regex --case --word --include '*.mbt' --exclude 'vendor/**'",
    context(),
  )
  let second = @workbench.plan("/grep next", context())
  let a : @protocol.SearchTextPayload = @json.from_json(first.params())
  let b : @protocol.SearchTextPayload = @json.from_json(second.params())
  assert_eq(a.query, "a b")
  assert_true(a.regex && a.case_sensitive && a.whole_word)
  assert_eq(a.include_glob, "*.mbt")
  assert_eq(a.exclude_glob, "vendor/**")
  assert_true(b.generation > a.generation)
  assert_eq(a.session_key, b.session_key)
}

///|
test "structural patterns retain individually quoted arguments" {
  let operation = @workbench.plan(
    "/semantic 'fn $F($A) { .. }' 'let $X = $V'",
    context(),
  )
  let payload : @protocol.SearchSemanticPayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.patterns, ["fn $F($A) { .. }", "let $X = $V"])
}

///|
test "Moon IDE uses one-based positions and hover converts to LSP coordinates" {
  let definition = @workbench.plan("/definition main.mbt 3 9", context())
  let hover = @workbench.plan("/hover main.mbt 3 9", context())
  let a : @protocol.MoonIdeNavigationPayload = @json.from_json(
    definition.params(),
  )
  let b : @protocol.LspHoverPayload = @json.from_json(hover.params())
  assert_eq((a.line, a.column), (3, 9))
  assert_eq((b.line, b.character), (2, 8))
  assert_eq(a.session, "conversation-1")
  assert_eq(b.session, "conversation-1")
}

///|
test "schedules use selected workspace and typed timing" {
  let operation = @workbench.plan(
    "/schedule every 30 'Daily check' 'Check the build'",
    context(),
  )
  let payload : @protocol.ScheduleSavePayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.spec.name, "Daily check")
  assert_eq(payload.spec.task, "Check the build")
  assert_eq(payload.spec.workspace, Some("/projects/work"))
  assert_eq(payload.spec.timing, @protocol.Every(30))
  assert_eq(payload.id, None)
  assert_true(!payload.run_now)
}

///|
test "job actions preserve generation, workspace and archive scope" {
  let operation = @workbench.plan("/jobs read generation-3 job-7 12", {
    ..context(),
    archived: true,
  })
  let payload : @protocol.JobReadPayload = @json.from_json(operation.params())
  assert_eq(payload.target.scope.session, "conversation-1")
  assert_eq(payload.target.scope.workspace, Some("/projects/work"))
  assert_true(payload.target.scope.archived)
  assert_eq(payload.target.generation, "generation-3")
  assert_eq(payload.target.job_id, "job-7")
  assert_eq(payload.offset, Some(12L))
}

///|
test "GitHub comments carry immutable review head and deliberate body" {
  let operation = @workbench.plan(
    "/github post https://github.com/u/r/pull/1 main.mbt 9 abc123 'Please fix this'",
    context(),
  )
  let payload : @protocol.GithubReviewMutationPayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.cwd, "/projects/work")
  assert_eq(payload.url, "https://github.com/u/r/pull/1")
  assert_true(
    payload.action
    is @protocol.Post(
      path="main.mbt",
      side="RIGHT",
      line=9,
      head="abc123",
      body="Please fix this"
    ),
  )
}

///|
test "Codex submission uses the curated payload and approval mode" {
  let operation = @workbench.plan(
    "/codex send thread-9 'Fix the bug'",
    context(),
  )
  let payload : @protocol.CodexTurnStartPayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.thread_id, "thread-9")
  assert_eq(payload.input, [{ "type": "text", "text": "Fix the bug" }])
  assert_eq(payload.permission_mode, @protocol.RequestApproval)
  assert_eq(payload.cwd, Some("/projects/work"))
}

///|
test "Codex reverse-request identities and JSON responses remain typed" {
  let operation = @workbench.plan(
    "/codex respond token-3 42 '{\"decision\":\"accept\"}'",
    context(),
  )
  let payload : @protocol.CodexServerRequestRespondPayload = @json.from_json(
    operation.params(),
  )
  assert_eq(payload.response_token, "token-3")
  assert_eq(payload.request_id, Json(42))
  assert_eq(payload.result, { "decision": "accept" })
}

///|
test "malformed and incomplete actions produce useful errors" {
  for
    input in [
      "/file 'unfinished", "/file", "/provider mystery", "/schedule every 0 name task",
      "/hover main.mbt 0 1", "/worktree remove", "/github checkout repo not-a-number",
      "/codex respond token id invalid", "/codex new model unknown", "/unknown",
    ] {
    try @workbench.plan(input, context()) catch {
      @workbench.InputError(message) => assert_true(!message.is_empty())
    } noraise {
      _ => fail("Expected an input error for " + input)
    }
  }
}

///|
test "workspace-dependent operations explain missing project selection" {
  try
    @workbench.plan("/find main.mbt", { ..context(), workspace: None, })
  catch {
    @workbench.InputError(message) => assert_true(message.contains("workspace"))
  } noraise {
    _ => fail("Expected a missing workspace error")
  }
}

///|
test "diff retains Unicode and both sides of changed text" {
  let lines = @workbench.line_diff(
    "same\nold 🌙\ntail", "same\nnew 月\ntail",
  )
  assert_eq(lines, [
    "--- original", "+++ working tree", "@@ -2,1 +2,1 @@", " same", "-old 🌙",
    "+new 月", " tail",
  ])
  assert_eq(@workbench.line_diff("same\n", "same\n"), ["No changes."])
}

///|
test "display preserves multiline tool and source output" {
  assert_eq(@workbench.display(Json("one\ntwo 🌙\n")), [
    "one", "  two 🌙", "  ",
  ])
  assert_eq(@workbench.display(Json::empty_object()), ["Done."])
}

///|
test "all feature families have typed operations" {
  let cases = [
    ("/settings", "settings.get"),
    ("/workspaces", "workspace.list"),
    ("/workspace add '/projects/a b'", "workspace.add"),
    ("/workspace-settings submodules off", "workspace.settings_set"),
    ("/skills catalog", "skills.catalog"),
    ("/skills install owner/module 1.0.0 skill", "skills.install"),
    ("/schedules", "schedules.list"),
    ("/schedule run schedule-1", "schedules.action"),
    ("/jobs", "jobs.list"),
    ("/files src", "fs.read_directory"),
    ("/history", "git.history"),
    ("/git changes", "git.changes"),
    ("/diff main.mbt", "git.original_file"),
    ("/github issues", "github.list"),
    ("/github review", "github.review"),
    ("/codex", "codex.thread.list"),
    ("/codex models", "codex.model.list"),
    ("/codex requests", "codex.server_request.list"),
    ("/auth", "auth.status"),
    ("/share", "session.share"),
    ("/export", "session.export"),
    ("/search 'A title'", "session.search"),
  ]
  for (input, expected) in cases {
    assert_eq(@workbench.plan(input, context()).command_name(), expected)
  }
}
