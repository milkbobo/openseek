# Desktop frontend: breaking up the root model

Status: in progress. Owner decisions are recorded under
[Decisions](#decisions); everything under [Work queue](#work-queue) is open.

## Goal

`desktop/frontend` is one Rabbita application whose root package holds a single
`Model`, a single `Msg` and a single `update`. The root has grown past what one
package can carry. The goal is a root that is thin glue: it owns navigation and
the invariants that span subsystems, and every subsystem with its own state
machine lives in its own package behind a small public contract with blackbox
tests.

Not goals: changing behavior, changing the wire protocol, or redesigning
state. An extraction that wants a behavior change stops and asks first.

The work is incremental on purpose. A one-shot version of this refactor was
written in July on the local `components` branch; it never merged and is now
about 1,900 commits behind `main`. Every step here is a change that can merge
on its own.

## Where it stands

Measured in `desktop/frontend` (the root package):

| | Before | Now |
|---|---|---|
| `update.mbt` | 21,808 lines | 8,815 lines |
| inline tests in `update.mbt` | 315 | 0 |
| `Model` fields | 90 | 76 |
| `Msg` variants | 163 | 140 |
| `DeviceMsg` variants | 62 | 60 |
| `update_msg` | 4,049 lines | 3,734 lines |
| `update_device_msg` | 2,744 lines | 2,684 lines |

Done:

1. **Tests left `update.mbt`.** Each of its 315 test blocks moved, byte for
   byte, into a `<domain>_wbtest.mbt` file named after the subsystem it
   exercises. Those files are the inventory for the extractions below: when a
   subsystem becomes a package, its `_wbtest.mbt` file is what turns into the
   package's blackbox tests.
2. **`remote_access` package** — the Settings page's relay sign-in. The
   smallest possible example of the template.
3. **`self_update` package** — the self-update flow. The example for a package
   that reports outward (`Event`) and takes an input it cannot know (`busy`).

4. **`host_settings` package** — the focused host's settings mirror, optimistic
   saves, setup modal, and API rows. The root supplies the focused channel and
   an emit that captures its connection generation, rejects stale/background
   device messages, and folds `AlignProvider`, `CloseMenu`, `OpenSettings`,
   `OpenExternal`, and `Problem` events. Revision absence is `None`; editable
   URL/key fields remain form text. Provider reads use `State::provider()`.
   The package has 19 blackbox tests; eight root tests cover its wiring.
   The former private OpenRouter patch test now exercises the actual bridge
   requests in the existing browser setup test, including clearing the preset.

Read the extracted packages before starting another extraction.

## The package template

Every extracted subsystem follows the same shape. `remote_access/` and
`self_update/` are the reference.

- **Files.** `state.mbt` (types, `update`), `requests.mbt` (bridge calls),
  `view.mbt`, `messages.mbt` (translations only this subsystem uses),
  `<name>_test.mbt` (blackbox tests), `moon.pkg` with `supported_targets =
  "js"`.
- **Signature.** `update(state, msg, emit) -> (State, Cmd)`, the Rabbita 0.16
  order. Older sibling packages (`jobs`, `github`, `fileeditor`) are
  `Cmd`-first; do not copy that.
- **Reporting outward.** When a transition needs something only the
  application can do (a toast, activating a conversation), `update` returns
  `(State, Cmd, Array[Event])` and the root folds the events in the same
  dispatch. `Event` is a `pub(all) enum` the package defines. There is no
  "nothing happened" variant: an empty array is no events. A package with
  nothing to report keeps the pair.
- **Inputs.** What the package cannot know arrives as a labelled argument
  (`busy~ : Bool`), computed by the root at the call site.
- **Views** talk out through `emit` (`on_click=emit(Clicked)`), never through
  events.
- **`State`** is a `pub struct` or `pub enum`: readable and matchable from the
  root, not constructible outside the package. `State::empty()` is the
  constructor, as in the sibling packages.
- **`Msg`** is `pub(all)` and carries raw wire payloads
  (`StatusLoaded(@protocol.AuthStatusPayload)`), so a blackbox test can build
  every message. Any projection of a payload happens in `update`, not in the
  bridge decoder or a request callback.
- **Tests are blackbox.** A test reaches a state by sending messages from
  `State::empty()` and asserts on readable fields and returned events. A
  whitebox test is acceptable only for a pure helper whose result is visible
  nowhere but in rendered HTML (`self_update/progress_wbtest.mbt`).
- **Shared view state.** `host_settings.Menu` is a view-only input carrying
  open/toggle/dismiss for the root-owned selector. It is never stored in
  package state. External-link clicks emit a message and then an event; the
  root executes the existing opener.
- **Device replies.** `host_settings` receives raw protocol payloads inside
  `Msg`. The root captures channel/generation in the command emit and checks
  them before forwarding a reply. Broadcasts use the same route with no
  request generation.
- **Root side.** One field (`self_update : @self_update.State`), one variant
  (`SelfUpdate(@self_update.Msg)`), one forwarding arm in `update_msg`. The
  root keeps tests only for its own wiring: an event becomes a toast, an input
  follows root state.

## Recipe for one extraction

1. Find the surface: the `Model` fields, the `Msg`/`DeviceMsg` variants, the
   arms in `update_msg`/`update_device_msg`, the views, the bridge decoders in
   `bridge.mbt`, and the translations. `grep -n` the field and variant names
   across `desktop/frontend/*.mbt`; do not trust this document's lists over the
   code.
2. Measure what the arms read from the rest of `Model`. Each read is an
   argument, an event, or a sign the boundary is wrong.
3. Create the package. Move code verbatim where possible; drop name prefixes
   the package name now supplies (`UpdateReady` becomes `Ready`).
4. Rewire the root: field, variant, forwarding arm, initial model, decoders,
   views, `moon.pkg` import.
5. Convert the domain's `_wbtest.mbt` tests to blackbox tests in the package.
   Tests that exercise root wiring stay in the root, rewritten to reach their
   state by messages.
6. Verify, from the repository root:

   ```bash
   touch desktop/frontend/*.mbt desktop/frontend/<pkg>/*.mbt
   moon check --target js --deny-warn
   moon test --target js -p openseek_desktop/frontend
   moon test --target js -p openseek_desktop/frontend/<pkg>
   moon info --target js
   moon fmt --check
   ```

   The test total across the root and the packages must not drop without an
   explanation in the commit message.
7. One commit per extraction, one pull request per extraction.

## Traps

- **`moon check` can report success from a stale cache.** `touch` the edited
  files first, as in the recipe.
- **`--deny-warn` finds what only tests kept alive.** Moving a test out of a
  regular file can leave a variant never constructed, a `derive(Debug)` never
  used, or an import unused in the production build. Step 1 found one dead
  `Msg` variant this way. Delete dead code after confirming no emitter exists,
  and retarget its tests to the live route rather than dropping them.
- **Private types whose `Debug` only tests use** carry
  `#warnings("-unused_value")` with a comment (`PullRequestProbe`,
  `StoredConversationModel`, `AppFontSize`, `LiveReasoning`). The attribute
  goes away when the type moves into a package and becomes `pub`.
- **Fixtures live in two files.** An inline test in a regular file cannot see
  a definition in a `_wbtest.mbt` file, and a regular-file function used only
  by `_wbtest.mbt` files is an unused-function error. So fixtures that
  `goal.mbt`, `worktrees.mbt`, `workspaces.mbt` and other regular files still
  use sit in the regular `test_fixtures.mbt`; the rest sit in
  `fixtures_wbtest.mbt` or beside their only user.
- **A root whitebox test can no longer build a package's state** with a struct
  literal. Reach it by sending messages (see `Model::with_staged_update` in
  `self_update_wbtest.mbt`).
- **`pkg.generated.mbti` for a js-only package** is written by
  `moon info --target js`. Check `git status` afterwards and revert any
  interface file you did not mean to change.
- **Desktop rules still apply:** no `derive(FromJson)`/`derive(ToJson)` under
  `desktop/`, explicit codecs only; no sentinel values for absence.

## Work queue

In suggested order. Each item is one pull request unless it says otherwise.

### 1. `preferences` — theme, language, type scale and the other page-local choices

- Fields (9): `system_dark`, `theme`, `language`, `locale`, `app_font_size`,
  `minimal_transcript`, `fps_overlay_enabled`, `notification_corner`,
  `tree_layout`.
- Messages (13): `SettingsLoaded`, `ThemeChanged`, `ColorSchemeChanged`,
  `LanguageLoaded`, `LanguageChanged`, `SystemLanguagesChanged`,
  `LanguageStorageFailed`, `FontSizeChanged`, `FontSizeAdjusted`,
  `FpsOverlayChanged`, `MinimalTranscriptChanged`,
  `NotificationCornerChanged`, `TreeLayoutChanged`.
- Tests waiting: `ui_preferences_wbtest.mbt` (6), `language_wbtest.mbt` (2).
- Three things make this less of a leaf than it looks; settle them before
  writing code:
  - `SettingsLoaded` also seeds the model picker (`default_model`,
    `conversation_models`, `default_agent`, the reasoning choices). Split the
    storage read into two messages, one per owner.
  - Theme and font changes push commands into the editor, terminal and
    transcript (`Theme::apply` in `dom_helpers.mbt`). Those are cross-package
    effects: return an event and let the root issue them.
  - `locale` is read about 215 times in the root. Keep those call sites
    cheap, for example with a `Model::locale()` accessor introduced in a
    preparatory commit that changes nothing else.
- If the three points cost more than the nine fields are worth, skip this
  item; it is the least valuable one in the queue.

### 2. The session core — devices, conversations and runs

This is where the weight is: `update_device_msg` (2,684 lines, 60 variants),
the `Send`/`ComposerAction` arms of `update_msg` (about 680 lines),
`DeviceState` (19 fields) and `Conversation` (37 fields). Goal, branch and
pull-request state, archive, steer, compaction and sub-runs are all fields of
`Conversation`, so they are slices of this item, not leaves of their own.

Coupling is narrower than the size suggests. `update_device_msg` reaches the
rest of `Model` almost only through `find_conversation`/`replace_conversation`
(23 uses each), `replace_device` (12), `focused` (14), `locale` (11) and
`notify_error` (7).

Proposed stages. The design below is a proposal, not a decision: confirm it
with the owner before starting stage B.

- **Stage A — move the types.** A package (working name `sessions`) receives
  `Conversation`, `DeviceState`, their lifecycle enums (`RunPhase`,
  `RunState`, `TranscriptSync`, …) and the pure methods on them, with no logic
  change. The root keeps its `devices` and `conversations` arrays. Large and
  mechanical; it removes the `#warnings` attributes on the moved types.
- **Stage B — move the state machine, one cluster per pull request.** The
  package gains `State { devices, conversations, … }` plus the counters that
  must outlive a conversation (`transcript_request_generation`,
  `submission_sequence`, `git_request_generation`, `websocket_epoch`,
  `page_namespace`) and
  `update(state, channel, msg, emit, …) -> (State, Cmd, Array[Event])`.
  Clusters, each with the `_wbtest.mbt` file that converts with it:

  | Cluster | Tests |
  |---|---|
  | connection: `BridgeReady`, `ChannelDown`, reconnect | `bridge_wbtest` (8) |
  | session lists, projects, worktrees | `session_list_wbtest` (9), inline tests in `workspaces.mbt` (27) and `worktrees.mbt` (20) |
  | archive | `archive_wbtest` (24) |
  | opening and loading a session | `session_open_wbtest` (20) |
  | transcript sync: commits, watermark, reload | `transcript_sync_wbtest` (25) |
  | run lifecycle, stream, steer, compaction | `run_lifecycle_wbtest` (37), `run_stream_wbtest` (22), `steer_wbtest` (14), `compaction_wbtest` (10) |
  | sub-runs and workflows | `subrun_wbtest` (9) |
  | goal, branch and pull request | inline tests in `goal.mbt` (31), `branch_wbtest` (7) |

- **What stays in the root:** which conversation is on screen (`focused`,
  `active_session`, `selected_conversation`, `loading_conversation`). That is
  navigation. The package reports "this session finished opening" as an event
  and the root decides whether it may take the screen, which keeps today's
  rule that a delayed reply cannot steal focus from another device.
- **Prior art:** the `components` branch built this package as
  `desktop/frontend/store` with 186 blackbox tests. The branch exists only in
  the owner's local checkout and is too stale to port, but its event set and
  its test driver are worth reading if you have access
  (`git show components:desktop/frontend/store/…`).

### 3. Finish moving tests out of regular files

`goal.mbt` (31), `workspaces.mbt` (27), `worktrees.mbt` (20), `console.mbt`
(14), `workspace_settings.mbt` (12) and a few smaller files still carry inline
tests. Most of them move with the session core. Once none is left,
`test_fixtures.mbt` becomes a `_wbtest.mbt` file and no test support remains
in the production build.

### What stays in the root for good

- The post-dispatch reconciliation in `update` (309 lines): closing menus on
  navigation, fencing Quick Open and the git popover, syncing the file panel,
  terminal, jobs, GitHub and the native browser view. It is the one owner of
  invariants that span subsystems. Splitting it into named steps is welcome;
  moving it out is not.
- Glue between packages that already exist: the browser pane (`preview` +
  `dock` + theme + file navigation), dock and right-panel layout, screen
  selection. These arms shrink as their neighbors leave.
- Toasts (`notifications`, `notify_error`). Every subsystem reports problems
  to it; it is where `Problem` events land.

## Decisions

Made by the owner on 2026-10-12.

| Decision | Reason |
|---|---|
| Incremental, one package per pull request | The one-shot `components` branch could not keep up with `main` |
| Blackbox tests per package | The state machine is the contract; whitebox tests hide it |
| `update(state, msg, emit) -> (State, Cmd)` | Rabbita 0.16 order, for every new package |
| `update` reports outward through returned `Array[Event]`, not an `on_x` callback | Outputs stay data; the root can react in the same dispatch, which the session core needs; one shape for leaves and the core |
| `Msg` carries raw wire payloads | A blackbox test must be able to build every message while `State` stays unconstructible |
| `#warnings("-unused_value")` on test-only `derive(Debug)` | Rewriting 30 assertions to drop `Debug` loses failure output and would be undone once the type is `pub` |
| Dead code a move exposes is deleted in that change, after asking | It is behavior-neutral; its tests move to the live route |

Left open: the session core's package name and event set (stage B), and
whether `@codex.update`'s existing `open_external` callback is converted to an
event when that package is next touched.

## Working on this

- Work sequentially. Every extraction edits `model.mbt`, `update.mbt`,
  `view.mbt` and `moon.pkg`; parallel extractions conflict, and each one so
  far has raised a question the owner had to answer.
- Rebase onto `main` before each extraction. The root package changes daily.
- Nobody has run the desktop application against these changes; the owner
  runs end-to-end checks. List the screens an extraction touched in its pull
  request so they can be clicked through.
