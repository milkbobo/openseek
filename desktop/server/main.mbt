// The desktop backend without a window: the same API state, engine and
// Codex supervisors, schedules, and host pumps the Proton host runs, served
// to a browser on the console listener or to one client on the process's own
// standard streams, instead of over the window bridge. Nothing in this module
// depends on Proton, so it builds on a machine with no window toolkit and
// runs headless — a container, a virtual machine, a remote box.

///|
/// Where this server's clients come from.
priv enum Front {
  // Browsers on loopback: the listener, and the page it serves them.
  Console(@remote.LocalConsole, page~ : @pathx.Path)
  // The one client that started this process and holds its standard streams.
  Stdio(@stdstreams.Streams)
}

///|
async fn main {
  let matches = command.parse(argv=@env.args()[1:], env=@env.get_env_vars())
  // Before anything else can start a process: a child would otherwise
  // inherit the client's channel as its own standard streams.
  let streams = if matches.flags.get("stdio") is Some(true) {
    Some(@stdstreams.claim())
  } else {
    None
  }
  guard matches.values.get("resource-dir") is Some([resource_dir, ..]) else {
    fail("--resource-dir (OPENSEEK_DESKTOP_RESOURCE_DIR) is required")
  }
  guard matches.values.get("port") is Some([port, ..]) else {
    fail("--port has no value")
  }
  let port = @string.parse_int(port)
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
  let codex_home = match runtime_dir {
    Some(dir) => @codex.prepared_home(dir)
    None => None
  }
  let codex = @codex.CodexSettings(command=@codex.command(), home=codex_home)
  // A headless process has no terminal to read: its standard output is a
  // pipe, which the C runtime buffers by the block, so log lines would sit
  // unseen until the buffer filled. The log goes to a file beside the rest of
  // the runtime state instead, as the window host's does.
  if runtime_dir is Some(dir) {
    let path = dir.join("openseek-server.log").to_string()
    @xlog.global().set_handler(@xlog.File(path))
  }
  // Like a development window host, the server persists no relay sign-in:
  // it may share the runtime directory with an installed application, and
  // one `auth.json` is one device token.
  let auth = @auth.AuthStore::load()
  let front = match streams {
    Some(streams) => Stdio(streams)
    // Only a browser needs the frontend bundle, so only this front looks
    // for it.
    None =>
      Console(
        @remote.LocalConsole::bind(port~),
        page=Path(@host.frontend_entry_path(resources)),
      )
  }
  let console_url = match front {
    Console(console, ..) => Some(console.entry_url())
    Stdio(_) => None
  }
  let state = @api.ApiState(
    engine~,
    codex~,
    runtime_dir?,
    executable?,
    auth~,
    console_url?,
    resources~,
  )
  let relay = @remote.RelayActor(state, announce=device => {
    @xlog.info() <? { "message": "relay registered", "device": device }
  })
  @async.with_task_group(group => {
    state.start_services(group)
    group.spawn_bg(allow_failure=true, () => relay.run())
    match front {
      Console(console, page~) => {
        @xlog.info() <?
          {
            "event": "desktop_server_serving",
            "origin": console.origin(),
            "root": page.dirname().to_string(),
            "engine": engine,
          }
        // The one line a person needs: the page to open, token included.
        // Written straight to the descriptor so it reaches a pipe or
        // `docker logs` at once instead of waiting in the runtime's output
        // buffer.
        @stdio.stdout.write("\{console.entry_url()}\n")
        console.run(
          state,
          root=page.dirname().to_string(),
          entry=page.basename().to_owned(),
        )
      }
      Stdio(streams) => {
        @xlog.info() <? { "event": "desktop_server_serving", "engine": engine }
        // The client's connection is this process's reason to run: when it
        // closes its end, everything started above stops with it.
        @remote.serve_lines(state, streams.input, streams.output)
        group.return_immediately(())
      }
    }
  })
}

///|
/// The server's command line; each option also reads an environment
/// variable, the way a supervised process is usually configured.
let command : @argparse.Command = Command(
  "seekmoon-server",
  about="The SeekMoon desktop backend, served to a browser on loopback or to one client on standard input and output.",
  options=[
    OptionArg(
      "resource-dir",
      long="resource-dir",
      env="OPENSEEK_DESKTOP_RESOURCE_DIR",
      about="The directory this host's bundled files live under: a package root holding seekmoon/, or a checkout's desktop/.",
    ),
    OptionArg(
      "port",
      long="port",
      env="OPENSEEK_DESKTOP_SERVER_PORT",
      default_values=["27183"],
      about="The loopback port to serve the console on; an ephemeral port is used when it is taken.",
    ),
  ],
  flags=[
    FlagArg(
      "stdio",
      long="stdio",
      about="Serve the one client holding this process's standard streams, a JSON-RPC message per line, instead of opening the console; exit when its input ends.",
    ),
    FlagArg(
      "packaged",
      long="packaged",
      about="Read --resource-dir as an installed package root rather than a checkout's desktop/.",
    ),
  ],
)
