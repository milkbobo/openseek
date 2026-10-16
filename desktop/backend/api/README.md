# Working-host service

`ApiState` owns the engine, Codex actor, schedules, language-service state,
and notification hub. Its public packages support native and wasm without a
Proton/CEF, native PTY, or desktop log dependency.

The embedding process supplies `HostConfig`.
Configuration names an absolute data directory, engine executable, Codex home
and executable, and explicit resource paths. Desktop resolves
its packaged tools and visualizer assets before constructing the service;
headless callers must supply their own build's resources. The shared service has no PTY dependency or `terminal.*` endpoints.
Desktop and relay connections add native terminals in `app/internal/host`.

Use `ApiState.start_services(group)` for embedded hosts; it prepares the shared
workspace registry and starts `run()` in the host task group. The daemon runs
`ApiState.run()` in its lifecycle task, with its explicitly selected registry.
Neither lifetime belongs to a client request.
It prepares the data directory and starts the engine, Codex, schedules, and LSP
pumps. Cancellation joins the actors and their children. A service instance is
single-use because engine shutdown closes its command mailbox.

Each transport constructs a `HostConnection`. Watches and searches remain
connection-owned; ending one connection does not stop the service. Service notifications use a bounded broadcast log, while watch
and terminal events return to their owning connection. `endpoints` supplies the
shared typed catalog; the desktop adapter adds window/system operations,
updates, and relay identity commands.

`remote.Client` schedules JSON-RPC on an already-connected WebSocket. The
headless CLI initializes each connection before passing it to `direct_client()`,
which applies service admission and connection-owned login cleanup. SSH
authentication, lifecycle, installation and reconnect belong to the
[CLI](../cli/README.md), [SSH client](../host_client/README.md) and installer.

The desktop installs its logging and directory providers through
`desktop/backend/native_runtime`; desktop owns
the final destination or upload of a conversation export rendered by the service.
