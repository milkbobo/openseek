// The desktop backend without a window: the same API state, engine and
// Codex supervisors, schedules, and host pumps the Proton host runs, served
// to one client on the process's own standard streams instead of over the
// window bridge. Nothing in this module depends on Proton, so it builds on a
// machine with no window toolkit and runs headless — a container, a virtual
// machine, a remote box.

///|
async fn main {
  let matches = command.parse(argv=@env.args()[1:], env=@env.get_env_vars())
  // The standard streams are the only front there is. Asking for it by name
  // keeps a bare launch from reading a terminal as a protocol stream.
  guard matches.flags.get("stdio") is Some(true) else {
    fail(
      "--stdio is required: the server's client is whoever holds its standard streams",
    )
  }
  // Before anything else can start a process: a child would otherwise
  // inherit the client's channel as its own standard streams.
  let streams = @stdstreams.claim()
  guard matches.values.get("resource-dir") is Some([resource_dir, ..]) else {
    fail("--resource-dir (OPENSEEK_DESKTOP_RESOURCE_DIR) is required")
  }
  // No window toolkit answers where this host's files are, so the launcher
  // says: the package root holding `seekmoon/`, or a checkout's `desktop/`.
  let resources : @resources.Resources = {
    dir: @pathx.Path(resource_dir).resolve().to_path(),
    packaged: matches.flags.get("packaged") is Some(true),
  }
  let executable = match @env.args() {
    [executable, ..] => Some(executable)
    [] => None
  }
  if @host.PackagedTools::resolve(Some(resources)) is Some(tools) {
    tools.apply_to_process_env()
  }
  let engine = @engine.engine_command(resources)
  let runtime_dir = match executable {
    Some(executable) => @host.prepared_runtime_dir(executable)
    None => None
  }
  // Before anything is read from or written to the runtime directory: this
  // host must be the only one serving from it.
  let ownership = match runtime_dir {
    Some(dir) => Some(@host.RuntimeOwnership::take(dir))
    None => None
  }
  defer (if ownership is Some(ownership) { ownership.release() })
  let codex_home = match runtime_dir {
    Some(dir) => @codex.prepared_home(dir)
    None => None
  }
  let codex = @codex.CodexSettings(command=@codex.command(), home=codex_home)
  // No terminal is watching this process, and its standard output belongs to
  // the client. The log goes to a file beside the rest of the runtime state,
  // as the window host's does.
  if runtime_dir is Some(dir) {
    let path = dir.join("openseek-server.log").to_string()
    @xlog.global().set_handler(@xlog.File(path))
  }
  // Like a development window host, the server persists no relay sign-in:
  // it may share the runtime directory with an installed application, and
  // one `auth.json` is one device token.
  let auth = @auth.AuthStore::load()
  let state = @api.ApiState(
    engine~,
    codex~,
    runtime_dir?,
    executable?,
    auth~,
    resources~,
  )
  let relay = @remote.RelayActor(state, announce=device => {
    @xlog.info() <? { "message": "relay registered", "device": device }
  })
  @async.with_task_group(group => {
    state.start_services(group)
    group.spawn_bg(allow_failure=true, () => relay.run())
    @xlog.info() <? { "event": "desktop_server_serving", "engine": engine }
    // The client's connection is this process's reason to run: when it closes
    // its end, everything started above stops with it.
    @remote.serve_lines(state, streams.input, streams.output)
    group.return_immediately(())
  })
}

///|
/// The server's command line; each option also reads an environment
/// variable, the way a supervised process is usually configured.
let command : @argparse.Command = Command(
  "seekmoon-server",
  about="The SeekMoon desktop backend, served to one client on standard input and output.",
  options=[
    OptionArg(
      "resource-dir",
      long="resource-dir",
      env="OPENSEEK_DESKTOP_RESOURCE_DIR",
      about="The directory this host's bundled files live under: a package root holding seekmoon/, or a checkout's desktop/.",
    ),
  ],
  flags=[
    FlagArg(
      "stdio",
      long="stdio",
      about="Serve the one client holding this process's standard streams, a JSON-RPC message per line, and exit when its input ends.",
    ),
    FlagArg(
      "packaged",
      long="packaged",
      about="Read --resource-dir as an installed package root rather than a checkout's desktop/.",
    ),
  ],
)
