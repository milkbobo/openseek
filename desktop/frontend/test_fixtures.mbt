///|
fn test_dispatch() -> @cmd.Emit[Msg] {
  Emit(_ => @cmd.none)
}

///|
/// Test-only: a device-scoped message as the page's one channel delivers it.
fn on_home(msg : DeviceMsg) -> Msg {
  FromDevice(@interop.ChannelId::Local, msg)
}

///|
/// Test-only: `update` with a device message on the page's one channel.
fn update_dev(
  dispatch : @cmd.Emit[Msg],
  msg : DeviceMsg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  update(dispatch, on_home(msg), model)
}

///|
/// A frontend resource fixture with the same validation as protocol input.
/// Keeping it as a channel method makes the owning device explicit in tests.
fn @interop.ChannelId::test_resource(
  self : @interop.ChannelId,
  path : String,
) -> @common.Uri raise {
  guard @resource.of_path(self, path) is Some(resource) else {
    fail("test resource path was invalid: \{path}")
  }
  resource
}

///|
/// The project every conversation fixture on this device belongs to. A
/// conversation is workspace-owned now, so the shared test model attaches
/// one project and puts its conversation in it.
fn @interop.ChannelId::test_project(self : @interop.ChannelId) -> @common.Uri {
  // Valid by construction; a total fixture keeps every test using
  // `test_model` free of a synthetic error effect.
  match @resource.of_path(self, "/work") {
    Some(root) => root
    None => @common.Uri::file("/work")
  }
}

///|
/// The durable store the fixture conversation's records live in — the store
/// root a commit or start for a conversation in `test_project` carries.
/// Derived from that project so the two cannot drift apart.
fn @interop.ChannelId::test_store_root(
  self : @interop.ChannelId,
) -> @common.Uri {
  let path = self.test_project().path + "/.openseek"
  match @resource.of_path(self, path) {
    Some(root) => root
    None => @common.Uri::file(path)
  }
}

///|
/// The worktree registry mirror a placement needs before it resolves. Rows
/// stay empty: the fixture conversation works in the project root.
fn @interop.ChannelId::test_worktrees(
  self : @interop.ChannelId,
) -> ProjectWorktrees {
  { project: self.test_project(), rows: [], generation: 0, }
}

///|
fn test_conversation() -> Conversation {
  empty_conversation(
    @interop.ChannelId::Local,
    "desktop-test",
    @interop.ChannelId::Local.test_project(),
  )
}

///|
fn test_reloading(buffered : Array[BufferedCommit]) -> TranscriptSync {
  Reloading(generation=1, attempt=1, buffered~, reload_after_current=false)
}

///|
fn test_model() -> Model {
  {
    ..initial_model(desktop=false)
    // The headless test runtime has no window to ask about focus, so the
    // model boots browser-shaped and every test here then runs
    // desktop-shaped: on an explicit Local channel, signed in to its own host.
    ,
    devices: [
      {
        ..empty_device_state(@interop.ChannelId::Local),
        bridge: Connected,
        projects: [@interop.ChannelId::Local.test_project()],
        worktrees: [@interop.ChannelId::Local.test_worktrees()],
      },
    ],
    focused: @interop.ChannelId::Local,
    console: local_console_state(login_return_to="/console/"),
    // A connected fixture has received a keyed host snapshot.
    host_settings: test_host_settings(has_deepseek_key=true),
    active_session: "desktop-test",
    conversations: [test_conversation()],
  }
}

///|
/// A file below the active checkout, keyed the way the dock and document
/// table hold it.
fn Model::test_file(self : Model, path : String) -> @common.Uri raise {
  guard self.workspace_resource(@pathx.Relative(path)) is Some(file) else {
    fail("test model must carry a checkout root")
  }
  file
}

///|
/// Test-only: the focused device's state; raising keeps a broken model a
/// test failure rather than a silent mismatch.
fn Model::dev(self : Model) -> DeviceState raise {
  guard self.focused_device() is Some(dev) else {
    fail("the model holds no focused device")
  }
  dev
}

///|
/// Test-only: the conversation on screen. A test that reads it has already
/// put one there, so its absence is a broken fixture; raising says so where
/// production code must instead take `active_conversation`'s `None` branch
/// and render onboarding.
fn Model::active(self : Model) -> Conversation raise {
  guard self.active_conversation() is Some(conv) else {
    fail("the model holds no active conversation")
  }
  conv
}

///|
/// Test-only: transform the focused device's state, e.g. seeding a session
/// list on `test_model()`.
fn Model::with_dev(
  self : Model,
  transform : (DeviceState) -> DeviceState,
) -> Model raise {
  self.replace_device(transform(self.dev()))
}

///|
fn sessions_loaded(
  items : Array[@transcript.SessionListItem],
  request_generation~ : Int32 = 0,
) -> Msg {
  on_home(SessionsLoaded(items, connection_generation=0, request_generation~))
}

///|
/// A `git.branch` reply for the test conversation.
fn branch_reply(
  branch : String,
  generation~ : Int32 = 0,
  session~ : String = "desktop-test",
  diffstat? : DiffStat,
  base_hint? : String,
) -> DeviceMsg {
  BranchLoaded(
    session~,
    branch=Some(branch),
    diffstat~,
    generation~,
    base_hint~,
  )
}

///|
/// A `git.pull_request` reply for the test conversation. `queried` defaults to
/// the branch asked about, which is the ordinary case: only a checkout that
/// moved mid-request makes them differ.
fn pull_request_reply(
  branch : String,
  generation~ : Int32,
  queried? : String,
  pull_request? : PullRequest,
  compare_url? : String,
) -> DeviceMsg {
  PullRequestLoaded(
    session="desktop-test",
    branch~,
    generation~,
    queried=Some(queried.unwrap_or(branch)),
    pull_request~,
    compare_url~,
  )
}

///|
/// One pull request, varied per test by field update.
fn test_pull_request() -> PullRequest {
  {
    number: 710,
    title: "Add a changed-files explorer",
    state: PullRequestOpen,
    draft: true,
    url: "https://github.test/acme/app/pull/710",
    base: "main",
    additions: 2972,
    deletions: 287,
    changed_files: 18,
    checks: Some({ passed: 1, failed: 0, pending: 3, }),
  }
}

///|
/// An archived row in `channel`'s fixture project store — where the fixture
/// conversation's record lives, so an archive fact about it addresses that
/// same durable identity.
fn archived_item(
  id : String,
  channel~ : @interop.ChannelId = Local,
) -> @transcript.SessionListItem {
  {
    id,
    title: Some(""),
    workspace: channel.test_project(),
    workspace_name: "work",
    updated_at_ms: None,
  }
}

///|
/// An archived row in `test_project` — the store the fixture conversation
/// lives in, so an archive fact about it addresses the same durable identity.
fn placed_archived_item(id : String) -> @transcript.SessionListItem {
  {
    id,
    title: Some(""),
    workspace: @interop.ChannelId::Local.test_project(),
    workspace_name: "work",
    updated_at_ms: None,
  }
}

///|
/// Test-only: a desktop-shaped model (browser tabs exist only where the
/// native views do), after one settling dispatch so the per-conversation
/// sync passes have claimed their owners — as any real first message has
/// long done before a tab can open.
fn desktop_model() -> Model {
  let model = { ..test_model(), is_desktop: true, }
  let (_, model) = update(
    test_dispatch(),
    Terminal(@terminal.TabSelected(key="missing-tab")),
    model,
  )
  model
}

///|
/// Reach a host mirror through the same messages used by the live bridge.
fn test_host_settings(
  provider~ : String = "deepseek",
  revision~ : Int32 = 0,
  custom_api_url~ : String = "",
  has_deepseek_key~ : Bool = false,
  has_glm_key~ : Bool = false,
  has_custom_key~ : Bool = false,
  followup_behavior~ : String = "steer",
  messages~ : Array[@host_settings.Msg] = [],
) -> @host_settings.State {
  let payload : @protocol.SettingsStatusPayload = {
    revision,
    provider,
    custom_api_url: Some(custom_api_url),
    has_deepseek_key,
    has_glm_key,
    has_custom_key,
    followup_behavior,
  }
  let mut state = @host_settings.State::empty()
  for msg in [@host_settings.Loaded(payload), ..messages] {
    let (next, _, _) = @host_settings.update(
      state,
      msg,
      @cmd.Emit(_ => @cmd.none),
      channel=Local,
      on_settings=false,
      locale=English,
    )
    state = next
  }
  state
}
