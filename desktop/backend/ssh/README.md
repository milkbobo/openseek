# SSH working hosts

The desktop uses the existing host-qualified channel and resource URI model:

```text
renderer -> native client -> local loopback TCP/WebSocket
         -> ssh -N -L -> remote loopback TCP/WebSocket -> openseek app-server
```

`ssh` authenticates using the user's key/agent and known-hosts configuration.
A separate bootstrap SSH command starts `openseek app-server` and reads its
loopback port and process instance ID. Bootstrap stdout is not an RPC transport.
The WebSocket initialize response must name the discovered instance. The server
rejects browser Origins and binds only `127.0.0.1`; forwarding also binds only
`127.0.0.1` and refuses a port collision. No application bearer token is added.

## Usage

Install the matching native CLI release on the remote host and run `openseek
setup`. The archive now includes the native `openseek-app-server` companion next
to `openseek`; `openseek app-server` launches that companion. This keeps Proton
out of the server and native PTY dependencies out of the portable engine module.
For a source build:

```sh
moon build . desktop/backend/server --target native --release
# Install both executables together in a directory on PATH:
# _build/native/release/build/moonbitlang/openseek/openseek.exe -> openseek
# _build/native/release/build/openseek_desktop/backend/server/server.exe -> openseek-app-server
```

Use **Add project → Add SSH remote…**, or **Settings → SSH remotes**. Enter
`ssh user@host`, `ssh alias`, or a command with `-p`, `-i`, `-J`, `-l`, or `-F`.
The parser preserves quoted arguments and never evaluates the input as a local
shell command. Put additional connection settings in SSH config. Password and
host-key prompts must first be completed in a terminal; batch-mode failures are
shown in the UI. The optional executable field names `openseek` on the remote
PATH or its absolute path, not a shell command.

Select **Add project** on the connected host, browse to a remote directory, and
add it. The sidebar combines local and remote projects, with host-qualified
identities. Chat, history, approvals, attachments, worktrees, file browsing,
file watching, search, Git changes/history/review, language navigation/hover,
and PTYs reuse the existing backend API and frontend components. MoonBit tools,
`rg`, Git and Codex must be available on the remote host. Remote Codex uses that
host's normal `~/.codex` credentials; sign in with `codex login --device-auth`
in the remote terminal, then refresh the account in settings.

## Lifetime and scope

This version is connection-owned, without a detached daemon, installation
manager, upgrade journal, or crash-recovery subsystem. Closing/reloading the
window or disconnecting terminates its bootstrap, tunnel, remote server, running
turns and PTYs. Conversation history and project registration remain on the
remote disk. Reconnect re-reads that state; it never replays an unanswered write.
Remote profiles persist locally in `~/.openseek/ssh-profiles.json` and start
offline when the app reopens. Local-only export, system file opening, document
preview and browser tooling retain their existing limits.

Each native connection has a monotonically increasing epoch. Native delivery
and frontend requests reject events/replies from retired connections. An absent
connection is `Unsent`, an explicit RPC error is `Refused`, and a lost reply is
`Unknown`; there is no fallback to the local host.

`SEEKMOON_SSH_PROFILES` isolates profile storage for QA. `OPENSEEK_APP_SERVER`
overrides the native companion path for source builds; `OPENSEEK_ENGINE`
overrides the engine used by that server.

## Validation

`tests/ssh/app_server.py SERVER ENGINE [SSH argv ...]` uses an offline model and
private HOME/workspace. Without SSH arguments it exercises loopback WebSocket;
with a same-filesystem test sshd it exercises the full `ssh -L` chain. It checks
chat/history, file notifications, PTY output/exit, Git, MoonBit hover and process
shutdown. The packaged desktop is the acceptance host for native profile,
connection, picker and renderer routing.
