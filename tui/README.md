# SeekMoon terminal client

SeekMoon's native TUI uses the same typed command catalog and backend services as the desktop app. It keeps the conversation sidebar on the left, files and review on the right, an editor/diff area, and a terminal sheet that opens at the bottom. Skills, Settings, and Scheduled tasks are navigable pages with editable controls and clickable actions. It supports OpenSeek and Codex conversations, persistent session history, project worktrees, approvals, file and Git review, skills, jobs, schedules, and real PTYs. The terminal UI library is vendored from `../vendor/tui`; the published mooncakes packages `tonyfettes/ghostty` and `moonbit-community/pty` provide terminal emulation and PTY support.

## Run

From the repository root:

```sh
just seekmoon-tui --workspace /absolute/path/to/project
```

The default starts a shared backend for the TUI's lifetime. The OpenSeek engine is built by the launcher. To inspect the interface without credentials or a model call:

```sh
just seekmoon-tui --demo
just seekmoon-tui --snapshot
just seekmoon-tui --demo --page skills
just seekmoon-tui --snapshot --page settings
```

For a persistent backend shared by multiple clients, keep this command running:

```sh
just seekmoon-server --port 27184 --ready-file /tmp/seekmoon-server.json
```

Then attach terminal clients:

```sh
just seekmoon-tui --server-file /tmp/seekmoon-server.json
```

A client can also use `--connect ws://127.0.0.1:27184/v1/devices/host/ws --token TOKEN`. The token can be supplied through `SEEKMOON_SERVER_TOKEN`. The readiness file contains the server URL and launch token and is created with private permissions on POSIX.

The standalone server can serve the desktop browser frontend with `--root PATH --entry FILE`. Its engine processes, sessions, settings, Codex actor, and notifications belong to that server. Each connected client owns its own terminal sessions and filesystem watches. Disconnecting a client closes its PTYs; model work continues in the persistent server.

The native Proton host and the standalone server both import the toolkit-independent `desktop/backend` library. The TUI's WebSocket client speaks the same authenticated JSON-RPC protocol as the desktop browser client; it does not start a second engine implementation.

## Controls

| Key | Action |
| --- | --- |
| Enter | Send the composer or open the selected sidebar conversation |
| Alt+Enter / Ctrl+J | Insert a newline |
| Ctrl+N | New conversation |
| Ctrl+1 / Ctrl+2 / Ctrl+3 / Ctrl+4 | Chat / Skills / Scheduled tasks / Settings |
| Ctrl+E | Toggle the editor |
| Ctrl+R | Toggle the right Files and Review sidebar |
| F6 | Cycle focus through the visible panes |
| Ctrl+B | Toggle and focus the sidebar |
| Ctrl+P / F1 | Show commands |
| Ctrl+T | Open the terminal pane or return to chat |
| Ctrl+Left / Ctrl+Right | Switch terminal tabs |
| Alt+W | Close the current terminal |
| Shift+PageUp / Shift+PageDown | Scroll terminal history |
| PageUp / PageDown | Scroll the active transcript or information panel |
| Tab | Accept a next-message prediction, otherwise switch sidebar/composer focus |
| Escape | Close an information panel and return to the composer |
| Ctrl+C | Stop the active turn or clear an idle composer |
| Ctrl+Q | Quit |

Text selection copies through OSC 52 when supported by the outer terminal. Mouse events inside the terminal pane are forwarded to programs that request them.

The left sidebar's Chats and Projects tabs switch between a flat chat list and expandable project groups. Select a project and press `n`, or click its `+`, to start a chat there. The tab bar's `+` opens an editable project-directory field; Enter registers it and Escape cancels. With the sidebar focused, Left/Right switch tabs and Up/Down/Enter navigate entries.

Settings has Engine, Codex, Remote and About categories. Ctrl+Left/Right switches categories; Tab selects fields or buttons and Enter activates them. Codex sign-in displays the browser authorization URL, while Remote exposes the shared server's relay connection status and controls. Skills offers searchable Installed and Catalog lists; Scheduled tasks has editable forms, lifecycle buttons, run logs and links back to run chats.

Use `/help` for the full command catalog. Paths and arguments in workbench commands support single quotes, double quotes, and backslash escapes. They are parsed as text and do not undergo shell expansion. `!COMMAND` and `/terminal COMMAND` deliberately run a shell command in the selected conversation checkout.

## Desktop workflows

| Workflow | Terminal interface |
| --- | --- |
| Chat and history | Composer, sidebar, `/new`, `/sessions`, `/open`, `/search`, `/rename`, `/fork` |
| Streaming and reasoning | Live assistant/reasoning text, tool rows, run status, model/reasoning selection |
| Follow-ups | `/queue on|off`, queued message editing/removal/steering, ordinary composer submission |
| Approvals | `/approvals`, `/approve`, `/deny`; Codex reverse requests retain their exact response token and request ID |
| Standing goals and compaction | `/goal`, `/goal clear`, `/compact`; plans render within tool messages |
| Archive and deletion | `/sessions archived`, `/archive`, `/unarchive`, `/delete`, explicit force confirmation for dirty worktrees |
| Projects | Expandable Projects sidebar with add/new-chat controls; `/workspaces`, `/workspace PATH`, `/workspace add|remove PATH` |
| Worktrees | `/worktree list|create|repair|remove`, `/workspace-settings` |
| Files and attachments | `/files`, `/browse`, `/mkdir`, `/file`, `/attach`, `/upload`, `/attachments`, `/detach`, `/edit` |
| Quick Open and search | `/find`, `/grep`, `/semantic`, include/exclude globs and text search flags |
| MoonBit navigation | `/definition`, `/references`, `/symbols`, `/hover`, `/diagnostics`, `/packages` |
| Local changes and Git history | `/git changes|branch|pr|commit|original`, `/diff`, `/history` |
| GitHub | PR/issue lists and details, checkout, review files and threads, explicit post/reply/delete/resolve actions |
| Skills | Installed/catalog listing, reading instructions, installation and removal |
| Jobs | Job lists, retained output paging, stop |
| Schedules | One-time and interval schedules, pause/resume/run/stop/delete |
| Provider settings | `/settings`, `/provider`, `/key`, `/followup` |
| Codex | `/mode codex|openseek`, `/codex list`, `/codex new`, `/codex open THREAD_ID`, integrated composer; accounts, models, history, reviews, skills, and requests |
| Export and share | `/export`, `/share`; the standalone server needs visualizer assets for HTML export |
| Terminal | Interactive shell, resize, keyboard/mouse input, scrollback, full-screen programs, terminal editors |

For OpenSeek, `/thinking off|high|max` selects reasoning. For Codex, use `/thinking none|minimal|low|medium|high|xhigh`; accepted efforts depend on the selected model.

File and code operations follow the conversation's registered worktree placement. Git comparison uses the server's immutable task baseline and preserves rename source paths. Search requests have monotonically increasing generations so a stale search cannot replace a newer query.

`/attach SERVER_PATH` attaches a file already on the server. `/upload LOCAL_PATH` uploads a client-local image or document, including when connected to a different server. `/attachments` lists the draft attachments; `/detach NUMBER` removes one. Images travel in the model image input, while PDFs, DOCX and XLSX originals retain file references. Attachments remain in the composer when a send fails.

Open a file from the right Files tree and use the built-in editor; Ctrl+S saves. The Review view opens changes in the diff editor. Terminal editors remain available through a shell in the bottom terminal sheet, for example `/terminal vim PATH`. Examples:

```text
/edit src/main.mbt
/grep 'SessionPayload' --include '*.mbt' --exclude 'vendor/**'
/semantic 'fn $F($A) { .. }'
/diff src/main.mbt
/skills catalog
/schedule every 60 'Check build' 'Run the build and report failures'
```

Switch the ordinary composer with `/mode codex` or `/mode openseek`. `/codex list`, `/codex new`, and `/codex open THREAD_ID` select Codex conversations; ordinary submission starts or steers their live turns. `/codex requests` shows pending questions, and `/codex approve TOKEN` or `/codex deny TOKEN` answers an approval.

Codex questions that require structured answers can be answered using `/codex respond TOKEN RESULT_JSON`. The response shape belongs to the displayed request method. Command and file approvals use `{"decision":"accept"}` or `{"decision":"decline"}`; user-input requests use `{"answers":{"question-id":{"answers":["answer"]}}}`.

## Terminal-specific limits

The built-in graphical browser and element picker have no TUI equivalent. Graphical document previews, canvas/image rendering, window controls, and desktop appearance controls use their terminal-appropriate alternatives: source/text views, local paths, external applications, or the terminal's own appearance. Authentication links can be opened in a separate browser. Actual shells and terminal editors run in server-owned PTYs and are not simulated.

## Package boundaries

- `tui/`: application state, keyboard/mouse navigation, transcript rendering and terminal panes.
- `tui/client`: authenticated native WebSocket client and typed request/reply correlation.
- `tui/workbench`: typed slash-command planning and execution for desktop feature workflows.
- `tui/pages`: navigable Skills, Settings and Scheduled tasks pages, form editing and backend actions.
- `tui/workspace`: right-side Files/Review navigation, editor tabs and diff editing.
- `tui/codexchat`: Codex thread snapshots, turn/item streaming reconciliation, reverse-request ordering and chat operations.
- `tui/terminal`: Ghostty terminal emulation and terminal input translation.
- `desktop/server`: a standalone host for the shared backend.

Run `just seekmoon-tui-test` for the TUI/client/server checks, and the root `just check`, `just test`, and `just build` integration gates for the complete workspace.
