///|
async fn invoke_shared(
  state : @api.ApiState,
  name : String,
  params : Json,
) -> Json {
  let endpoints = @api.endpoints(state, HostConnection())
  let matching = endpoints.filter(endpoint => endpoint.name() == name)
  assert_eq(matching.length(), 1)
  matching[0].invoke(params)
}

///|
async test "shared endpoints persist preferences and drafts without a window" {
  let dir = @fs.tmpdir(prefix="seekmoon-shared-endpoints-")
  defer @fs.rmdir(dir, recursive=true)
  let state = @api.ApiState(engine="unused-test-engine", runtime_dir=Path(dir))
  let language : @protocol.UiLanguagePreference = @json.from_json(
    invoke_shared(state, "app.language_get", {}),
  )
  assert_true(language.language is None)
  ignore(invoke_shared(state, "app.language_set", { "language": "zh-Hans" }))
  let url = "https://github.example/owner/repo/pull/42"
  let draft : @protocol.GithubDraft = {
    target: Line(path="src/main.mbt", side="RIGHT", line=8, head="revision"),
    body: "Keep the shared host draft.",
  }
  let drafts : @protocol.GithubDrafts = { url, drafts: [draft], }
  ignore(invoke_shared(state, "github.drafts_set", drafts.to_json()))
  let reopened = @api.ApiState(
    engine="unused-test-engine",
    runtime_dir=Path(dir),
  )
  let saved_language : @protocol.UiLanguagePreference = @json.from_json(
    invoke_shared(reopened, "app.language_get", {}),
  )
  assert_eq(saved_language.language, Some("zh-Hans"))
  let saved_drafts : @protocol.GithubDrafts = @json.from_json(
    invoke_shared(reopened, "github.drafts_get", { "url": url }),
  )
  assert_eq(saved_drafts.url, url)
  assert_true(saved_drafts.drafts == [draft])
  ignore(
    invoke_shared(reopened, "github.drafts_set", { "url": url, "drafts": [] }),
  )
  let cleared : @protocol.GithubDrafts = @json.from_json(
    invoke_shared(state, "github.drafts_get", { "url": url }),
  )
  assert_true(cleared.drafts.is_empty())
}

///|
async test "shared endpoints resolve previews and report signed-out sharing" {
  let dir = @fs.tmpdir(prefix="seekmoon-shared-preview-")
  defer @fs.rmdir(dir, recursive=true)
  let file = "\{dir}/preview.pdf"
  @fs.write_file(file, "%PDF-1.7\n%%EOF\n")
  let state = @api.ApiState(engine="unused-test-engine")
  let payload : Json = { "session": "preview-test", "path": file }
  let preview : @protocol.OpenPathReply = @json.from_json(
    invoke_shared(state, "host.open_path_preview", payload),
  )
  assert_true(preview is Editor(_))
  @fs.remove(file)
  let missing : @protocol.OpenPathReply = @json.from_json(
    invoke_shared(state, "host.open_path_preview", payload),
  )
  assert_true(missing is Refused(_))
  let share : @protocol.SessionShareReply = @json.from_json(
    invoke_shared(state, "session.share", {
      "session": "preview-test",
      "workspace": dir,
      "title": "Shared session",
      "archived": false,
    }),
  )
  assert_true(share is SignInRequired)
}
