///|
const TranscriptReloadMaxAttempts : Int32 = 3

///|
/// Write a large selection through the Host only after the user submits it.
/// This still sends every match and its source in one request. Proton 0.2.11
/// rejects serialized payloads above 1 MiB before the Host can write the file;
/// the Host's artifact-size limit does not make those requests transferable.
/// The callback identifies this submission without carrying its draft again.
fn PendingSemanticSubmission::materialize(
  self : PendingSemanticSubmission,
  dispatch : @cmd.Emit[Msg],
  owner : @interop.ConversationKey,
) -> @cmd.Cmd {
  let reference = self.reference
  let submission_id = self.submission_id
  let pattern_count = reference.patterns.length()
  let payload = reference.materialize_payload(root=reference.root)
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let reply : @protocol.MaterializeSemanticSelectionReply = @interop.bridge_request(
        owner.channel,
        @commands.fs_materialize_semantic_selection,
        payload,
      ) catch {
        error => {
          scheduler.add(
            dispatch(
              SemanticSelectionMaterializationFailed(
                owner~,
                submission_id~,
                message=@interop.bridge_error_text(error),
              ),
            ),
          )
          return
        }
      }
      scheduler.add(
        dispatch(
          SemanticSelectionMaterialized(owner~, submission_id~, artifact={
            path: reply.path,
            pattern_count,
            match_count: reply.match_count,
          }),
        ),
      )
    })
    |> ignore
  })
}

///|
/// Show the Search explorer filtered to the selection a semantic composer chip
/// stands for. The chip is the live selection itself, so nothing is restored.
fn open_semantic_selection(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (@cmd.Cmd, Model) {
  let (open_cmd, opened) = open_explorer(
    dispatch,
    model,
    @fileeditor.ExplorerSearch,
  )
  let (filter_cmd, filtered) = update_msg(
    dispatch,
    FileEditor(
      @fileeditor.Search(
        @grep_search.SetSemanticResultFilter(
          @grep_search.SelectedSemanticResults,
        ),
      ),
    ),
    opened,
  )
  (@cmd.batch([open_cmd, filter_cmd]), filtered)
}

///|
/// Build the request for one transcript generation. Foreground loads may
/// activate a selected stored session; background refreshes only reconcile
/// the conversation already in the model.
fn session_snapshot_command(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
  session : String,
  generation : Int32,
  activate_on_success : Bool,
) -> @cmd.Cmd {
  let (workspace, archived) = match model.find_conversation(channel, session) {
    Some(conv) => (Some(conv.project()), conv.is_archived_read_only())
    None => (model.session_project(channel, session), false)
  }
  if activate_on_success {
    open_session(dispatch, channel, session, workspace~, generation~, archived~)
  } else {
    refresh_session(
      dispatch,
      channel,
      session,
      workspace~,
      generation~,
      archived~,
    )
  }
}

///|
/// Move the UI's focus to `channel`: refetch the focused-scoped mirrors
/// that BridgeReady only loads for the then-focused device (host settings,
/// installed skills) and reset their local bookkeeping, so
/// nothing of the previous device's host bleeds through. The active
/// conversation is the caller's to place afterwards (an activation or a
/// rotation); until it does, nothing is selected. A no-op when focus is
/// already there — or when the page does not hold the channel. A browser
/// console may select its inert `Local` default while its required remote
/// device is unavailable; that transition only clears device-scoped state.
fn focus_channel(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  channel : @interop.ChannelId,
) -> (@cmd.Cmd, Model) {
  guard channel != model.focused else { return (@cmd.none, model) }
  let focus_cmd = if model.device_state(channel) is Some(dev) {
    @cmd.batch([
      fetch_host_settings(dispatch, channel, dev.connection_generation),
      fetch_installed_skills(dispatch, channel),
      // Let update advance the catalog generations after focus moves. Calling
      // the request method against the old state would reuse an old token.
      dispatch(Codex(channel~, @codex.Msg::refresh())),
    ])
  } else if channel == @interop.ChannelId::Local {
    // Inert Local: a browser console whose required device is unavailable
    // (the desktop window always holds its Local channel, so it never gets
    // here). Focus returns to the default with nothing to fetch.
    @cmd.none
  } else {
    return (@cmd.none, model)
  }
  let (file_panel, unwatch_cmd) = model.file_panel.retire_watcher(
    dispatch.map(msg => FileEditor(msg)),
    file_ctx(model),
  )
  (
    @cmd.batch([focus_cmd, unwatch_cmd]),
    {
      ..model.clear_host_settings(),
      focused: channel,
      active_session: "",
      selected_conversation: None,
      conversation_load_failure: None,
      loading_conversation: None,
      installed_skills: [],
      // Codex is host-owned just like the other focused mirrors. Clear the
      // previous device's account and conversation list before its replies
      // can be mistaken for this device's sidebar section.
      codex: @codex.State(loading=true),
      // The old HostConnection is already parked. Preserve the remaining
      // owner/root state until the post-dispatch sync retires its file-index
      // cache and re-roots against the newly focused host.
      file_panel,
    },
  )
}

///|
/// The OpenSession body against an explicit channel — the caller has
/// already moved focus there, so `channel == model.focused` throughout.
fn open_session_on(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
  session_id : String,
) -> (@cmd.Cmd, Model) {
  let owner : @interop.ConversationKey = { channel, session: session_id, }
  if session_id == model.active_session {
    let base = { ..model, screen: Chat, }.mark_visible_conversation_read()
    // Re-selecting is an explicit catch-up point for writes made by an
    // idle CLI or another client. It also restarts an exhausted retry
    // round; an existing request stays single-flight. A fresh chat has no
    // durable record to read, including when returning here from Skills.
    match model.find_conversation(channel, session_id) {
      Some(conv) if !(conv.sync is Reloading(..)) &&
        model.can_reload_transcript(conv) => {
        let (next, generation) = base.begin_transcript_reload(conv)
        let next = { ..next, loading_conversation: Some(owner), }
        if generation is Some(generation) {
          (
            session_snapshot_command(
              dispatch, channel, next, session_id, generation, true,
            ),
            next,
          )
        } else {
          (@cmd.none, next)
        }
      }
      _ =>
        (
          @cmd.none,
          {
            ..base,
            loading_conversation: if base.loading_conversation
              is Some(loading_owner) &&
              loading_owner == owner {
              Some(owner)
            } else {
              None
            },
          },
        )
    }
  } else if model.find_conversation(channel, session_id) is Some(conv) {
    // Switching focus; the transcript re-pins at the tail. The store is
    // also re-read behind the switch — the local copy may date from
    // before a reconnect, or another client may be driving this
    // conversation — and the current view stays on screen while the
    // reply is in flight. A failed/ongoing first load also needs to stay
    // attached even though it has no transcript yet.
    let reread = model.can_reload_transcript(conv) || !(conv.sync is Synced)
    let (model, generation) = if reread {
      model.begin_transcript_reload(conv)
    } else {
      (model.replace_conversation(conv), None)
    }
    let next = {
      ..model.activate(channel, session_id, conv.project()),
      screen: Chat,
      loading_conversation: if generation is Some(_) {
        Some(owner)
      } else {
        None
      },
    }.with_active_project(Some(conv.project()))
    let commands : Array[@cmd.Cmd] = []
    if generation is Some(generation) {
      commands.push(
        session_snapshot_command(
          dispatch, channel, next, session_id, generation, true,
        ),
      )
    }
    (@cmd.batch(commands), next)
  } else {
    // The sidebar item says which project store holds the session, while the
    // already-loaded worktree registry may place it in a specific checkout.
    // Join both snapshots before the conversation exists: no later registry
    // reply is guaranteed after a user opens an already-listed session.
    //
    // A session this page can place in no project is not openable: there is
    // no store to read it from. That is a row on its way out — its project
    // was detached — so the click is dropped rather than reported.
    guard model.session_project(channel, session_id) is Some(project) else {
      return (@cmd.none, model)
    }
    let conversation = empty_conversation(
      channel,
      session_id,
      project,
      // Reopening a stored conversation recovers the tier it was left on,
      // not whatever was picked last in some other chat.
      model=model
        .remembered_model(channel, session_id)
        .unwrap_or(model.default_model),
    )
    let conversation = if model.device_state(channel) is Some(dev) {
      {
        ..conversation,
        workspace: dev.conversation_workspace(
          project,
          session_id,
          conversation.workspace,
        ),
      }
    } else {
      conversation
    }
    let (model, generation) = model.begin_transcript_reload(conversation)
    let next = { ..model, screen: Chat, loading_conversation: Some(owner), }.with_active_project(
      Some(project),
    )
    if generation is Some(generation) {
      (
        session_snapshot_command(
          dispatch, channel, next, session_id, generation, true,
        ),
        next,
      )
    } else {
      (@cmd.none, next)
    }
  }
}

///|
fn Model::live_selection(
  self : Model,
  channel : @interop.ChannelId,
  session : String,
) -> ConversationSelection? {
  self
  .session_project(channel, session)
  .map(workspace => { channel, session, workspace, record: LiveRecord, })
}

///|
/// Open one archived row against its archived durable twin. Reusing an
/// already-open archived transcript preserves its rendered snapshot while a
/// fresh generation catches up. A live same-id entry or an archived twin from
/// another store is replaced, so neither writable state nor an in-flight
/// snapshot can cross the store-qualified archive boundary.
fn Model::open_archived_session_on(
  self : Model,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session_id : String,
  workspace : @common.Uri,
) -> (@cmd.Cmd, Model) {
  let owner : @interop.ConversationKey = { channel, session: session_id, }
  let known = self.find_conversation(channel, session_id)
  let conversation = match known {
    Some(conv) if conv.is_archived_read_only() && conv.project() == workspace =>
      conv
    _ =>
      {
        ..empty_conversation(
          channel,
          session_id,
          workspace,
          model=self
            .remembered_model(channel, session_id)
            .unwrap_or(self.default_model),
        ),
        record: ArchivedRecord,
      }
  }
  let conversation = if self.device_state(channel) is Some(dev) {
    {
      ..conversation,
      record: ArchivedRecord,
      workspace: dev.conversation_workspace(
        workspace,
        session_id,
        conversation.workspace,
      ),
    }
  } else {
    { ..conversation, record: ArchivedRecord, }
  }
  let (model, generation) = self.begin_transcript_reload(conversation)
  let next = {
    ..model.activate(channel, session_id, workspace),
    screen: Chat,
    loading_conversation: Some(owner),
  }.with_active_project(Some(workspace))
  if generation is Some(generation) {
    (
      session_snapshot_command(
        dispatch, channel, next, session_id, generation, true,
      ),
      next,
    )
  } else {
    (@cmd.none, next)
  }
}

///|
/// Issue a live-session list request with a page-lifetime token. The token is
/// advanced before the command leaves update, so any older same-connection
/// reply is stale even if it returns last.
fn request_sessions_refresh(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.device_state(channel) is Some(dev) else {
    return (@cmd.none, model)
  }
  let request_generation = dev.sessions_request_generation + 1
  (
    fetch_sessions(
      dispatch,
      channel,
      dev.connection_generation,
      request_generation,
    ),
    model.replace_device({
      ..dev,
      sessions_request_generation: request_generation,
    }),
  )
}

///|
/// The archived list is fetched independently from the live list and keeps
/// its own token, so a newer live-only refresh does not invalidate a useful
/// archived reply.
fn request_archived_refresh(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.device_state(channel) is Some(dev) else {
    return (@cmd.none, model)
  }
  let request_generation = dev.archived_request_generation + 1
  (
    fetch_archived(
      dispatch,
      channel,
      dev.connection_generation,
      request_generation,
    ),
    model.replace_device({
      ..dev,
      archived_request_generation: request_generation,
    }),
  )
}

///|
/// Adopt one canonical workspace registry snapshot. Conversations from a
/// detached workspace leave this page with its sidebar section: their durable
/// records stay on disk and return when the directory is attached again. If
/// the active conversation leaves, select the newest remaining durable chat,
/// or rotate a fresh one into a project that stayed.
///
/// This is also the transition out of onboarding: a page with nothing on
/// screen — the app just started, or a project has been attached to a device
/// that had none — opens its first chat from here, because the registry is
/// the first thing that says a chat has anywhere to live.
fn adopt_projects(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
  paths : Array[@common.Uri],
) -> (@cmd.Cmd, Model) {
  guard model.device_state(channel) is Some(dev) else {
    return (@cmd.none, model)
  }
  // A pending add whose reply already resolved its registry row waits here
  // for that row to exist: the snapshot that contains it consumes the
  // pending and focuses. A snapshot without the row leaves it waiting —
  // a list read begun before our commit is still current-generation and
  // must not eat the focus the commit broadcast is about to deliver. An
  // unresolved pending stays untouched too: a snapshot alone cannot say
  // which row is ours (another client's commit broadcasts through this
  // same path), so it must never be guessed from one.
  let (focus_target, model) = match model.pending_project_adoption {
    Some(pending) if pending.channel == channel &&
      pending.resolved is Some(target) &&
      paths.contains(target) =>
      (Some(target), { ..model, pending_project_adoption: None, })
    _ => (None, model)
  }
  let selected_detached = channel == model.focused &&
    model.conversation_selection() is Some(selected) &&
    selected.channel == channel &&
    !paths.contains(selected.workspace)
  let active_project = if dev.active_project is None ||
    (dev.active_project is Some(active) && paths.contains(active)) {
    dev.active_project
  } else {
    None
  }
  // Each workspace's worktree list and settings mirror refresh with the
  // adopted registry; a detached workspace's cached rows drop with its
  // section. One request token per collection covers the whole fan-out
  // round.
  let worktrees_request_generation = dev.worktrees_request_generation + 1
  let workspace_settings_request_generation = dev.workspace_settings_request_generation +
    1
  let commands : Array[@cmd.Cmd] = []
  for path in paths {
    commands.push(
      fetch_worktrees(
        dispatch,
        channel,
        path,
        dev.connection_generation,
        worktrees_request_generation,
      ),
    )
    commands.push(
      fetch_workspace_settings(
        dispatch,
        channel,
        path,
        dev.connection_generation,
        workspace_settings_request_generation,
      ),
    )
  }
  let worktrees = dev.worktrees.filter(group => paths.contains(group.project))
  let workspace_settings = dev.workspace_settings.filter(row => {
    paths.contains(row.project)
  })
  // The old whole-session snapshot can outlive the workspace commit
  // broadcast. Prune it immediately so neither the sidebar nor fallback
  // selection can retain a conversation whose store is no longer attached.
  let sessions = dev.sessions.filter(item => paths.contains(item.workspace))
  let conversations = model.conversations.filter(conv => {
    conv.device != channel || paths.contains(conv.project())
  })
  let loading_conversation = if model.loading_conversation is Some(owner) &&
    owner.channel == channel &&
    !conversations.any(conv => {
      conv.device == owner.channel && conv.session_id == owner.session
    }) {
    None
  } else {
    model.loading_conversation
  }
  let (refresh_cmd, next) = request_sessions_refresh(dispatch, channel, {
    ..model.replace_device({
      ..dev,
      sessions,
      projects: paths,
      active_project,
      worktrees,
      worktrees_request_generation,
      workspace_settings,
      workspace_settings_request_generation,
    }),
    conversations,
    loading_conversation,
  })
  commands.push(refresh_cmd)
  if selected_detached {
    if focus_target is Some(project) {
      // This snapshot both removed the active conversation's project and
      // carries the row the user just added: the explicit add-and-focus
      // wins over fallback selection. NewChatIn rotates the fresh chat; the
      // dead session identity clears now so no render can address it while
      // the rotation is in flight (same rule as the fallback below).
      let (focus_cmd, focused) = update(
        dispatch,
        NewChatIn(channel, Some(project)),
        next,
      )
      commands.push(focus_cmd)
      commands.push(reveal_active_project())
      return (
        @cmd.batch(commands),
        {
          ..focused,
          active_session: "",
          selected_conversation: None,
          conversation_load_failure: None,
          loading_conversation: None,
          screen: Chat,
        },
      )
    }
    if sessions.get(0) is Some(fallback) {
      // The retained list is newest-first. Activate its first entry before
      // starting the reload so no render can address the detached session id
      // while the snapshot is in flight.
      let activated = next
        .activate(channel, fallback.id, fallback.workspace)
        .with_active_project(Some(fallback.workspace))
      // The session list names only the project store. Reconcile that broad
      // placement with the registry and any already-known conversation before
      // reloading: a retained Worktree must not be downgraded to Project, while
      // a session not yet materialized on this page still initializes from its
      // listed project.
      let activated = match activated.active_conversation() {
        Some(fallback_conv) =>
          activated.replace_conversation({
            ..fallback_conv,
            workspace: dev.conversation_workspace(
              fallback.workspace,
              fallback.id,
              fallback_conv.workspace,
            ),
          })
        // `activate` just placed this session, so it is on screen.
        None => activated
      }
      let (fallback_cmd, next) = open_session_on(
        dispatch,
        channel,
        activated,
        fallback.id,
      )
      commands.push(fallback_cmd)
      return (@cmd.batch(commands), next)
    }
    // Nothing is left to select on this device. Session ids are generated
    // inside a Cmd so update remains pure: clear the dead identity now, and
    // rotate a fresh chat into a project that survived (`target_project`
    // picks one). With no project left there is nowhere to rotate into, and
    // the view falls to onboarding until one is attached.
    if !paths.is_empty() {
      commands.push(rotate_session(dispatch, channel))
    }
    return (
      @cmd.batch(commands),
      {
        ..next,
        active_session: "",
        selected_conversation: None,
        conversation_load_failure: None,
        loading_conversation: None,
        screen: Chat,
      },
    )
  }
  if focus_target is Some(project) {
    // The confirmed add just committed: focus its project the way the
    // row's own ＋ does — activate it and start a fresh chat inside — and
    // scroll the newly active row into a long sidebar's view.
    let (focus_cmd, focused) = update(
      dispatch,
      NewChatIn(channel, Some(project)),
      next,
    )
    commands.push(focus_cmd)
    commands.push(reveal_active_project())
    return (@cmd.batch(commands), focused)
  }
  // Nothing is on screen and this device now has somewhere to put a chat:
  // the app's own startup rotation lands here, because it is issued before
  // the registry has answered and has no project to place until it does.
  if channel == next.focused &&
    next.active_conversation() is None &&
    !paths.is_empty() {
    commands.push(rotate_session(dispatch, channel))
  }
  (@cmd.batch(commands), next)
}

///|
/// Retry one failed generation without losing commits that arrived while its
/// snapshot was in flight. Three attempts form one bounded round. Exhaustion
/// keeps the buffer; a later commit/reconnect/open starts a fresh generation,
/// which is what an exhausted background round waits for.
fn retry_session_snapshot(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
  session : String,
  generation : Int32,
  activate_on_success : Bool,
  message : String,
) -> (@cmd.Cmd, Model) {
  guard model.find_conversation(channel, session) is Some(conv) &&
    conv.sync
    is Reloading(generation=current, attempt~, buffered~, reload_after_current~) &&
    current == generation else {
    return (@cmd.none, model)
  }
  if attempt < TranscriptReloadMaxAttempts {
    let next_attempt = attempt + 1
    let next = model.replace_conversation({
      ..conv,
      sync: Reloading(
        generation~,
        attempt=next_attempt,
        buffered=buffered.copy(),
        reload_after_current~,
      ),
    })
    let delay_ms = match next_attempt {
      2 => 250
      _ => 500
    }
    (
      @cmd.delay(
        session_snapshot_command(
          dispatch, channel, next, session, generation, activate_on_success,
        ),
        delay_ms,
      ),
      next,
    )
  } else {
    let failed = {
      ..conv,
      sync: ReloadFailed(generation~, buffered=buffered.copy()),
    }
    let next = model.replace_conversation(failed)
    let scroll = @cmd.none
    let owner : @interop.ConversationKey = { channel, session, }
    if activate_on_success &&
      model.loading_conversation is Some(loading_owner) &&
      loading_owner == owner {
      let blocking_failure = !next.selected_conversation_loaded()
      let (toast, next) = next.notify_error(
        dispatch,
        TranscriptRefreshFailedNotice + " (" + message + ")",
      )
      let (sessions, next) = if conv.is_archived_read_only() {
        request_archived_refresh(dispatch, channel, next)
      } else {
        request_sessions_refresh(dispatch, channel, next)
      }
      (
        @cmd.batch([toast, sessions, scroll]),
        {
          ..next,
          loading_conversation: None,
          conversation_load_failure: match next.selected_conversation {
            Some(target) if blocking_failure &&
              target.channel == channel &&
              target.session == session => Some({ target, message, })
            _ => None
          },
        },
      )
    } else {
      (scroll, next)
    }
  }
}

///|
/// Fold one current-generation snapshot into its conversation. Lower
/// watermarks retry instead of rolling the transcript back; stale generations
/// are no-ops. Buffered gaps start one new background generation. A
/// foreground result activates only if it still owns `loading_conversation`.
fn apply_session_snapshot(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  model : Model,
  session : String,
  items : Array[@transcript.TranscriptItem],
  watermark : Int32,
  goal : @transcript.GoalStanding?,
  goal_markers : Array[(Int32, @transcript.GoalMarker)],
  generation : Int32,
  activate_on_success : Bool,
  prediction : @wire.PredictionRecord?,
) -> (@cmd.Cmd, Model) {
  guard model.find_conversation(channel, session) is Some(conv) &&
    conv.sync is Reloading(generation=current, reload_after_current~, ..) &&
    current == generation else {
    return (@cmd.none, model)
  }
  if watermark < conv.watermark {
    return retry_session_snapshot(
      dispatch,
      channel,
      model,
      session,
      generation,
      activate_on_success,
      "failed to load session \{session}: snapshot watermark moved backwards",
    )
  }
  let (conv, gapped) = conv.adopt_snapshot(
    items,
    watermark,
    goal~,
    goal_markers~,
  )
  let conv = conv.with_prediction(prediction)
  let mut next = model.replace_conversation(conv)
  let commands : Array[@cmd.Cmd] = []
  let owner : @interop.ConversationKey = { channel, session, }
  if activate_on_success &&
    model.loading_conversation is Some(loading_owner) &&
    loading_owner == owner {
    next = {
      ..next.activate(channel, session, conv.project()),
      loading_conversation: None,
      conversation_load_failure: None,
    }
    // An archived transcript has no runnable checkout to inspect here. Its
    // retained workspace placement is still available to file links, but git
    // state is refreshed only after an unarchive turns the record live.
    if !conv.is_archived_read_only() {
      let (branch_cmd, probed) = probe_branch(
        dispatch,
        next,
        channel,
        session,
        next.conversation_root(conv),
      )
      next = probed
      commands.push(branch_cmd)
    }
  }
  if gapped || reload_after_current {
    guard next.find_conversation(channel, session) is Some(conv) else {
      return (@cmd.batch(commands), next)
    }
    let (reloading, next_generation) = next.begin_transcript_reload(conv)
    next = reloading
    if next_generation is Some(next_generation) {
      commands.push(
        session_snapshot_command(
          dispatch, channel, next, session, next_generation, false,
        ),
      )
    }
  }
  (@cmd.batch(commands), next)
}

///|
/// Whether an event the engine emits while idle (between turns) — the
/// compaction lifecycle, background-job notices, and the failure of an
/// idle-time durable append — so the routing must match by last run id: the
/// run that owned the id has already cleared `active_run_id` by the time
/// these arrive.
fn is_idle_event(event : @transcript.EngineEvent) -> Bool {
  match event {
    CompactionStarted
    | CompactionFinished(_)
    | CompactionFailed(_)
    | SessionAppendFailed(_)
    | BackgroundNotice(_) => true
    _ => false
  }
}

///|
fn is_steer_receipt(event : @transcript.EngineEvent) -> Bool {
  event is (SteerApplied(..) | SteerDropped(..))
}

///|
/// A chip's raw jump path as the root-relative form the panel and the host's
/// rooted ops speak. The steady state is the identity: chips
/// minted since the panel started recording relative names are already
/// relative. An older envelope can still carry an absolute path; those are
/// brought back inside against the conversation root, and `None` — an
/// absolute path outside anything this
/// conversation knows — means there is nothing the panel could open.
fn conversation_relative(
  model : Model,
  conv : Conversation,
  path : String,
) -> @pathx.Relative? {
  guard @resource.of_path(conv.device, path) is Some(absolute) else {
    // A string that is not a complete absolute path keeps its existing
    // workspace-relative interpretation.
    return Some(Relative(path))
  }
  if model.conversation_root(conv) is Some(root) &&
    @resource.relative_to(absolute, root) is Some(rest) &&
    !rest.is_root() {
    return Some(rest)
  }
  None
}

///|
/// Begin a non-transcript editor navigation. Transcript links capture this
/// page-lifetime token before their asynchronous host lookup; advancing it at
/// every competing navigation makes the user's latest action authoritative.
fn Model::begin_editor_navigation(self : Model) -> Model {
  {
    ..self,
    pending_review_context: None,
    file_panel: {
      ..self.file_panel,
      file_link_generation: self.file_panel.file_link_generation + 1,
    },
  }
}

///|
/// Open the shared Explorer picker on one of its three inventories. Dock and
/// panel visibility belong to the shell; inventory selection, focus, and any
/// host-backed refresh belong to fileeditor.
fn open_explorer(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  mode : @fileeditor.ExplorerMode,
) -> (@cmd.Cmd, Model) {
  let model = model.begin_editor_navigation()
  let screen = if model.screen is Codex { Screen::Codex } else { Chat }
  let next = {
    ..model,
    screen,
    dock: @dock.open_picker(model.dock),
    right_panel_open: true,
    right_panel_menu_open: false,
    // Invoking any Explorer inventory is an explicit request to keep it next
    // to the selected file on wide layouts. Narrow file opens still perform
    // the normal drill-down and close this tree.
    file_panel: { ..model.file_panel, tree_open: true, },
  }
  let (cmd, file_panel) = @fileeditor.update(
    dispatch.map(msg => FileEditor(msg)),
    @fileeditor.ExplorerModeSelected(mode),
    next.file_panel,
    file_ctx(next),
  )
  // Opening the picker hides the focused launcher. Hand focus to the panel
  // first; inventory-specific commands can then focus their own input.
  (@cmd.batch([focus_dock_after_render(), cmd]), { ..next, file_panel, })
}

///|
/// Reveal a transcript-linked directory in the editor's Files tree. Keep an
/// active file visible beside the tree; otherwise activate the picker body so
/// the reveal has a visible home. `RevealDirectory` expands the ancestors;
/// transcript navigation additionally expands the target itself, without
/// toggling an already-open row closed.
fn reveal_local_directory(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  path : @pathx.Relative,
) -> (@cmd.Cmd, Model) {
  let dock = match model.dock.active {
    Some(File(_)) | Some(FilePicker) => model.dock
    None
    | Some(Browser(_))
    | Some(GitDiff(_))
    | Some(Workflows)
    | Some(Jobs)
    | Some(Github) => @dock.open_picker(model.dock)
  }
  let model = {
    ..model,
    dock,
    right_panel_open: true,
    right_panel_menu_open: false,
  }
  let (cmd, panel) = @fileeditor.update(
    dispatch.map(msg => FileEditor(msg)),
    @fileeditor.RevealDirectory(path),
    model.file_panel,
    file_ctx(model),
  )
  let model = { ..model, file_panel: panel, }
  if path.is_root() || panel.expanded.contains(path) {
    return (cmd, model)
  }
  let (expand_cmd, panel) = @fileeditor.update(
    dispatch.map(msg => FileEditor(msg)),
    @fileeditor.DirToggle(path),
    panel,
    file_ctx(model),
  )
  (@cmd.batch([cmd, expand_cmd]), { ..model, file_panel: panel, })
}

///|
/// Bring a path into the workspace shown on screen. Codex file mentions come
/// from app-server's fuzzy search and are normally already relative; an
/// absolute value is accepted only inside the selected Codex thread's cwd.
fn Model::active_relative_path(self : Model, path : String) -> @pathx.Relative? {
  if self.screen is Codex {
    guard self.active_checkout() is Some(active) &&
      active.placement is Some(placement) &&
      placement.checkout_root() is Some(workspace) else {
      return None
    }
    if @resource.of_path(self.focused, path) is Some(absolute) {
      guard @resource.relative_to(absolute, workspace) is Some(rest) &&
        !rest.is_root() else {
        return None
      }
      return Some(rest)
    }
    return Some(Relative(path))
  }
  guard self.active_conversation() is Some(conv) else { return None }
  conversation_relative(self, conv, path)
}

///|
/// Run an accepted slash command against the active conversation and close the
/// completion menu. The command text is cleared from the composer; an unknown
/// id just dismisses the menu.
fn run_slash_command(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  command : String,
) -> (@cmd.Cmd, Model) {
  guard model.active_conversation() is Some(conv) &&
    !conv.is_archived_read_only() else {
    return (@cmd.none, model)
  }
  match command {
    "compact" =>
      // One compaction at a time: a repeat while one is queued or in flight
      // would stack another behind it in the engine's pending queue (the
      // host rejects it anyway) — swallow it like any settled command.
      if !(conv.compaction is NotCompacting) {
        (@cmd.none, { ..model.replace_conversation({ ..conv, task: "", }), })
      } else {
        (
          compact_openseek(
            dispatch,
            model.focused,
            session=conv.session_id,
            model=conv.engine_model,
            reasoning=model.reasoning_for(conv.engine_model),
            max_steps=model.max_steps,
            workspace=conv.project(),
          ),
          {
            ..model.replace_conversation({
              ..conv,
              task: "",
              // Hold the send gate before the host answers: mid-turn the
              // command queues behind the open run, and an idle request may
              // sit in the spawn/write window for seconds (a resumed
              // conversation gets its engine spawned on demand) — a prompt
              // sent into either gap would be consumed and rejected instead
              // of held. compaction_started confirms; CompactRejected clears.
              compaction: if conv.is_running() {
                Queued
              } else {
                Requested
              },
            }),
          },
        )
      }
    "goal" =>
      (
        @cmd.none,
        {
          ..model.replace_conversation({
            ..conv,
            task: "",
            goal_edit: Some({ draft: conv.goal_draft_seed(), }),
          }),
        },
      )
    _ => (@cmd.none, model)
  }
}

///|
/// Send one conversation's goal set (`Some`) or clear (`None`) to its engine.
/// Everything the command needs — session, workspace, launch mode — comes
/// from that conversation, so it cannot land on whichever one happens to be
/// active by the time the request goes out.
fn send_goal(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  conv : Conversation,
  command : String,
  text : String?,
) -> @cmd.Cmd {
  if conv.goal_creates_worktree() is Some(workspace) {
    return set_goal_in_new_worktree(
      locale=model.locale,
      dispatch,
      conv.device,
      conv.session_id,
      workspace,
      conv.engine_model,
      model.reasoning_for(conv.engine_model),
      model.max_steps,
      command,
      text,
    )
  }
  goal_openseek(
    dispatch,
    conv.device,
    session=conv.session_id,
    model=conv.engine_model,
    reasoning=model.reasoning_for(conv.engine_model),
    max_steps=model.max_steps,
    workspace=conv.project(),
    command,
    text,
  )
}

///|
/// Whether an engine event reports progress on the open step's model request,
/// which ends a pending retry notice: the replacement attempt produced output
/// or completed (a tool-only response has no deltas, so its usage report or
/// tool result is the first sign), or the step moved on or the run ended.
/// Events about other work in the same run say nothing about that request.
fn ends_retry(event : @transcript.EngineEvent) -> Bool {
  match event {
    AssistantDelta(_)
    | ReasoningDelta(_)
    | ReasoningMessage(_)
    | AssistantMessage(_)
    | Usage(..)
    | ToolResult(..)
    | ToolCallDecodeError(..)
    | AgentStep(_)
    | AgentFinished(_)
    | ContextYield(_)
    | AgentAborted(_)
    | MaxStepsExhausted
    | AgentSetupFailed(_) => true
    StreamRetry(..)
    | BackgroundNotice(_)
    | SubrunOpened(..)
    | SubrunClosed(..)
    | WorkflowOpened(..)
    | WorkflowClosed(..)
    | SteerApplied(..)
    | SteerDropped(..)
    | AutoCompactionFinished(_)
    | CompactionStarted
    | CompactionFinished(_)
    | CompactionFailed(_)
    | ApprovalRequested(..)
    | ApprovalResolved(..)
    | SessionAppendFailed(_) => false
  }
}

///|
/// Fold one engine event into its conversation. Returns the new conversation
/// and, when the event reported a failure the durable record will never carry,
/// the text to raise as a toast — the caller owns the dispatch a toast needs.
fn apply_engine_event(
  conv : Conversation,
  event : @transcript.EngineEvent,
  event_run_id : String?,
) -> (String?, Conversation) {
  // A retry notice lasts until the engine reports progress on the request it
  // is retrying; events about other work in the run leave it in place.
  let conv = if ends_retry(event) {
    { ..conv, turn: { ..conv.turn, retrying: None, }, }
  } else {
    conv
  }
  match event {
    AgentStep(step) => {
      // The next model request starts after every durable commit this page
      // already knows, including commits buffered during a reload. Advancing
      // the frontier per step prevents an earlier step's identical reasoning
      // from being mistaken for this step's commit.
      let reasoning_frontier = conv.durable_frontier()
      let cleared = conv.clear_streams()
      let conv = { ..cleared, turn: { ..cleared.turn, reasoning_frontier, }, }
      (
        None,
        // A step can only advance an open, uncancelled turn: after a Stop the
        // stage stays Cancelling (steering a dying turn is refused, so the
        // display must not flip the gate back open), and a stray step for a
        // closed run changes nothing.
        if conv.run is Open(run_id~, stage~) && !(stage is Cancelling) {
          { ..conv, run: Open(run_id~, stage=AtStep(step)), }
        } else {
          conv
        },
      )
    }
    // The engine is waiting out a backoff before reopening this step's
    // provider request. Drop every delta of the failed attempt so the
    // replacement stream cannot be concatenated with it, and show the retry
    // in the heartbeat until `ends_retry`; the step and every durable row
    // stay as they are.
    StreamRetry(attempt~, max_attempts~, reason~) => {
      let cleared = conv.clear_streams()
      (
        None,
        {
          ..cleared,
          turn: {
            ..cleared.turn,
            retrying: Some({ attempt, max_attempts, reason, }),
          },
        },
      )
    }
    AssistantDelta(content) =>
      if content.is_empty() {
        (None, conv)
      } else {
        let conv = conv.complete_reasoning()
        let carried = conv.turn.streaming_response.unwrap_or("")
        (
          None,
          {
            ..conv,
            turn: { ..conv.turn, streaming_response: Some(carried + content), },
          },
        )
      }
    ReasoningDelta(content) =>
      if content.is_empty() ||
        conv.turn.live_reasoning is Some({ complete: true, .. }) {
        // A completed semantic event is the boundary. A delayed fragment must
        // not resurrect or mutate the finished preview.
        (None, conv)
      } else {
        let carried = match conv.turn.live_reasoning {
          Some(reasoning) => reasoning.content
          None => ""
        }
        (
          None,
          {
            ..conv,
            turn: {
              ..conv.turn,
              live_reasoning: Some({
                content: carried + content,
                complete: false,
              }),
            },
          },
        )
      }
    // Full semantic events never append transcript items: the store commit is
    // the sole durable source. The complete reasoning payload replaces any
    // accumulated fragments and seals their transient presentation.
    ReasoningMessage(content) => {
      let normalized = content.trim()
      if normalized.is_empty() {
        // Remote delivery strips the complete payload because the durable
        // session event carries it. A remote client may have joined midway
        // through the stream, so its accumulated deltas can be only a suffix;
        // discard that provisional text at settlement and let the canonical
        // commit supply the complete Markdown card.
        (None, { ..conv, turn: { ..conv.turn, live_reasoning: None, }, })
      } else {
        (
          None,
          {
            ..conv,
            turn: {
              ..conv.turn,
              live_reasoning: Some({ content, complete: true, }),
            },
          },
        )
      }
    }
    AssistantMessage(_) => (None, conv.complete_reasoning().clear_response())
    // A background-job completion notice while idle. The durable record owns
    // the transcript card, and the completion is already surfaced to the
    // model as a steer — a toast would double it for an idle reader without
    // adding anything the card does not say.
    BackgroundNotice(_) => (None, conv)
    // A sub-run opened: the lane replaces the notice this used to be, so the
    // minutes it blocks for read as activity rather than silence. A repeated
    // id (a reconnect replaying the bracket) refreshes rather than doubles.
    // The lane docks above the composer, so opening one does not grow the
    // transcript and must not drag a pinned conversation down.
    // A workflow's brackets. The run is recorded for the Workflows tab; its
    // children arrive through the sub-run brackets the host synthesizes from
    // the run's sidecar (below), and resolve through `WorkflowEntryArrived`.
    // Nothing is dropped on close: a finished run is exactly what a reader
    // looks back over.
    WorkflowOpened(id~, first_child~, child_count~, ..) =>
      (
        None,
        {
          ..conv,
          workflows: @workflow.opened(
            conv.workflows,
            id~,
            session=conv.session_id,
            first_child~,
            child_count~,
          ),
        },
      )
    WorkflowClosed(id~) =>
      (None, { ..conv, workflows: @workflow.closed(conv.workflows, id~), })
    SubrunOpened(id~, kind~, label~) => {
      let subruns = conv.turn.subruns.filter(lane => lane.id != id)
      subruns.push({
        id,
        kind,
        label,
        steps: 0,
        activity: "",
        run: event_run_id,
      })
      (
        None,
        {
          ..conv,
          turn: { ..conv.turn, subruns, },
          // A child of a known workflow gets its row here, from the same
          // bracket that opened its lane.
          workflows: @workflow.child_opened(conv.workflows, id~, kind~, label~),
        },
      )
    }
    // Closed: always drop the lane. A captured sub-run already settles as the
    // durable tool brief, so repeating its status here would leave two
    // completion rows. Only an abnormal terminal status needs a local notice.
    //
    // The error goes in the retained OVERLAY, not in `messages`: the finish of
    // the enclosing run starts a snapshot whose `adopt_snapshot` replaces
    // `messages` wholesale, which would erase a non-durable error bubble.
    SubrunClosed(id~, status~, steps~, tokens~, unaccounted~) => {
      let closed = conv.turn.subruns.filter(lane => lane.id == id)
      let conv = {
        ..conv,
        turn: {
          ..conv.turn,
          subruns: conv.turn.subruns.filter(lane => lane.id != id),
        },
        workflows: @workflow.child_closed(
          conv.workflows,
          id~,
          status~,
          steps~,
          tokens~,
          unaccounted?,
        ),
      }
      if status == "captured" {
        (None, conv)
      } else {
        let kind = match closed {
          [lane, ..] => lane.kind
          [] => "subrun"
        }
        // Counts that are not the child's own account are not shown as if
        // they were: unknown spend is not zero spend.
        let cost = match unaccounted {
          Some(_) => "usage unknown"
          None => "\{steps} step(s) · \{@labels.compact_count(tokens)} tok"
        }
        (Some("\{kind} \{id}: \{status} · \{cost}"), conv)
      }
    }
    Usage(prompt_tokens~, completion_tokens~) =>
      (
        None,
        {
          ..conv,
          turn: {
            ..conv.turn,
            usage_tokens: prompt_tokens + completion_tokens,
          },
        },
      )
    ToolResult(..) => (None, conv)
    // The turn loop records this as an error `tool_result`; its commit is the
    // one canonical transcript source, just like a successful tool result.
    ToolCallDecodeError(..) => (None, conv)
    // A turn cannot end while a tool inside it is still blocked, so a terminal
    // event means the question died with the turn — the engine settles it as
    // cancelled on its way out. Clearing here is what stops a card from
    // outliving the run it belongs to and offering to answer nothing.
    AgentFinished(_)
    | ContextYield(_)
    | AgentAborted(_)
    | AgentSetupFailed(_) =>
      (None, { ..conv.clear_streams(), pending_approval: None, })
    MaxStepsExhausted =>
      (None, { ..conv.clear_streams(), pending_approval: None, })
    // A tool is blocked until this is answered. It replaces whatever card was
    // showing: the engine asks one question at a time, so an unretired older
    // one is a card this client failed to clear, not a second live question.
    ApprovalRequested(id~, tool_name~, detail~, body~) =>
      (
        None,
        {
          ..conv,
          pending_approval: Some({
            id,
            run_id: event_run_id,
            tool_name,
            detail,
            body,
            answered: false,
          }),
        },
      )
    // Settled — by this client, by another one, or by the engine's deadline.
    // Matched by id so a late settlement for an older question cannot retire
    // the card for a newer one.
    ApprovalResolved(id~) =>
      if conv.pending_approval is Some(pending) && pending.id == id {
        (None, { ..conv, pending_approval: None, })
      } else {
        (None, conv)
      }
    // The steer took effect at a step boundary. Its durable user item arrives
    // through `session.event`; the live event only settles pending UI.
    SteerApplied(content~, submission_id~) => {
      ignore(content)
      if submission_id is Some(submission_id) {
        let (next, _) = conv.acknowledge_steer(submission_id, event_run_id)
        // A queued row can receive its steer receipt before the direct queue
        // RPC reply. The receipt is stronger: the text was consumed.
        let (next, _) = next.remove_queued_input(submission_id)
        (None, next)
      } else {
        // Legacy receipt: lifecycle information only. Text is not ownership
        // in a multi-client session, even when it happens to match.
        (None, conv)
      }
    }
    // The steer raced the turn's end through the pipes and was rejected; the
    // text must not vanish silently.
    SteerDropped(content=_, submission_id~) =>
      if submission_id is Some(submission_id) {
        let (next, removed) = conv.reject_steer(submission_id, event_run_id)
        (if removed { Some(SteerDroppedNotice) } else { None }, next)
      } else {
        (None, conv)
      }
    AutoCompactionFinished(_) => (None, conv)
    CompactionStarted => (None, { ..conv, compaction: Compacting, })
    CompactionFinished(_) => (None, { ..conv, compaction: NotCompacting, })
    // An idle-time append the engine could not persist. It names what failed
    // but not which command asked for it, so nothing is settled on it — a
    // pending goal keeps waiting, since this may have been some other item's
    // append and its own may still land. What it does buy is the word: the
    // failure stops being silent, and the row's own text and actions are
    // what the user recovers with.
    SessionAppendFailed(error) => {
      let content = if error.is_blank() {
        "the engine could not save an item to this session"
      } else {
        "the engine could not save an item to this session: \{error}"
      }
      (Some(content), conv)
    }
    CompactionFailed(reason) => {
      let content = if reason.is_blank() {
        "compaction failed"
      } else {
        "compaction failed: \{reason}"
      }
      (Some(content), { ..conv, compaction: NotCompacting, })
    }
  }
}

///|
/// The selected OpenSeek conversation or Codex task, with its single resolved
/// directory placement. Owner identity remains separate because it fences
/// asynchronous replies even while placement is unresolved or missing.
priv struct ActiveCheckout {
  owner : @interop.ConversationKey
  placement : @interop.CheckoutPlacement?
}

///|
/// Select the same owner and placement for transcript links, Files, Terminal,
/// and language services. This is the only screen-dependent directory choice;
/// downstream packages merely project roots from `placement`.
fn Model::active_checkout(self : Model) -> ActiveCheckout? {
  if self.screen is Codex {
    guard self.codex.active_id() is Some(session) else { return None }
    return Some({
      owner: { channel: self.focused, session, },
      placement: self.codex.active_placement(self.focused),
    })
  }
  guard self.active_conversation() is Some(conv) else { return None }
  Some({
    owner: { channel: conv.device, session: conv.session_id, },
    placement: self.conversation_placement(conv),
  })
}

///|
/// The file-editor package's read-only projection of the selected checkout.
fn file_ctx(model : Model) -> @fileeditor.Ctx {
  let active = model
    .active_checkout()
    .unwrap_or({
      owner: { channel: model.focused, session: "", },
      placement: None,
    })
  // A cwd-less Codex task has a valid scratch Terminal identity but app-server
  // exposes no path that Files or language services may address. Keep the one
  // typed placement in Codex state, then project this capability as absent at
  // the file-editor boundary rather than inventing a directory.
  let file_placement = match active.placement {
    Some(@interop.Scratch(root=None)) if model.screen is Codex => None
    placement => placement
  }
  let engine_model = model
    .find_conversation(active.owner.channel, active.owner.session)
    .map(conv => conv.engine_model)
    .unwrap_or(model.default_model)
  let file_body_visible = match model.dock.active {
    Some(File(_)) | Some(GitDiff(_)) | Some(FilePicker) => true
    None | Some(Browser(_)) | Some(Workflows) | Some(Jobs) | Some(Github) =>
      false
  }
  {
    // Keep the real identity even while placement is unresolved or missing.
    // Both panel packages use the typed checkout state to park host work; the
    // stable owner lets an interrupted changed-file review resume after Repair
    // without ever treating the project root as a fallback checkout.
    owner: active.owner,
    locale: model.locale,
    model: engine_model.wire(),
    thinking: engine_model.thinking(model.reasoning_for(engine_model)),
    request_epoch: model.file_panel.request_epoch,
    // The native bridge and its watcher survive a page reload. Namespace the
    // panel's monotonic counter with this page's existing random identity so
    // a reloaded frontend cannot reuse the outgoing page's watcher token.
    watch_namespace: model.page_namespace + "-watch",
    placement: file_placement,
    dark_mode: model.theme.is_dark(model.system_dark),
    tree_layout: model.tree_layout,
    narrow: model.narrow,
    // The dock's projection: strip membership and the active tab are the
    // dock's truth, handed to the file subsystem read-only.
    // The dock preference survives Skills/Settings navigation, and an open
    // dock can instead show its browser or empty-strip launcher. CSS hides the
    // file body in all three cases. Report actual visibility so the file
    // subsystem parks its workspace watches and Changes refreshes off-screen.
    panel_open: model.right_panel_open &&
    (model.screen is Codex || (model.screen is Chat && file_body_visible)),
    open_files: @dock.file_paths(model.dock),
    preview_files: model.preview.local_files(),
    preview_rechecks: model.preview.files_to_check(),
    active_file: @dock.active_file(model.dock),
    open_history_diffs: @dock.history_diffs(model.dock),
    active_history_diff: @dock.active_history_diff(model.dock),
    github: model.github,
  }
}

///|
/// The terminal package's view of the active conversation. On the Codex page,
/// the selected app-server thread supplies the PTY session id and cwd. The
/// focused device owns every PTY opened from either source; a remote connection
/// is considered unavailable from its first socket loss because its old PTYs
/// are torn down at that boundary, even before the page escalates to BridgeLost.
fn terminal_ctx(model : Model) -> @terminal.Ctx {
  let active = model
    .active_checkout()
    .unwrap_or({
      owner: { channel: model.focused, session: "", },
      placement: None,
    })
  let connected = match model.device_state(active.owner.channel) {
    Some(dev) => dev.bridge is Connected && dev.reconnect_failures == 0
    None => false
  }
  @terminal.Ctx(
    channel=active.owner.channel,
    session=active.owner.session,
    placement=active.placement,
    dark_mode=model.theme.is_dark(model.system_dark),
    connected~,
  )
}

///|
/// Reconcile the dock strip, then the file subsystem, with the active
/// conversation after every message (see `@dock.sync` /
/// `@fileeditor.sync`). Order matters: the dock parks/restores the strip
/// first, so the file sync sees the fresh projection and re-roots its
/// document table from it. Centralizing it here keeps every
/// conversation-switching handler from having to re-root the panel itself.
fn sync_file_panel(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (Model, @cmd.Cmd) {
  let ctx = file_ctx(model)
  // Placement health is carried separately from identity, so a missing
  // checkout keeps this conversation's strip while both content subsystems
  // refuse host-backed work until Repair settles.
  let dock = @dock.sync(model.dock, ctx.owner)
  let model = { ..model, dock, }
  let (panel, cmd) = @fileeditor.sync(
    dispatch.map(msg => FileEditor(msg)),
    model.file_panel,
    file_ctx(model),
    review_context=@mention_context.review_changes(
      (if model.screen is Codex {
        model.codex_composer_input().draft.mentions
      } else {
        model.active_conversation().map(conv => conv.mentions).unwrap_or([])
      }).map(mention => mention.ref_),
    ),
  )
  ({ ..model, file_panel: panel, }, cmd)
}

///|
/// Whether a full-screen surface is drawn over the window. Every overlay
/// `view.mbt` appends after the shell (see its trailing `children.push`
/// block) belongs here: native views z-order above all HTML, so an overlay
/// this predicate forgets renders with the browser pane punched through it,
/// swallowing the clicks that land there.
fn covering_overlay(model : Model) -> Bool {
  (model.narrow && model.sidebar_open) ||
  model.project_picker is Some(_) ||
  model.export_dialog.is_open() ||
  model.workspace_settings_dialog is Some(_) ||
  model.archive_confirm is Some(_) ||
  model.archived_delete_confirm is Some(_) ||
  model.quick_open.is_open() ||
  model.api_setup_open ||
  model.update_ux is ConfirmingRestart(_) ||
  // Best effort: with the bridge gone the hide op may not deliver.
  model.bridge_state() is BridgeLost(_)
}

///|
/// Which browser page's native view belongs on screen: the active Browser
/// tab's, once it has a URL (a blank tab has no view yet) — and only while
/// the pane is actually visible and uncovered. Native views z-order above
/// all HTML, so anything the frontend draws over the pane area — the `+`
/// launcher popup, a dock tab menu, the narrow layout's sidebar drawer, a
/// custom select, the composer's Git popover, and every `covering_overlay` —
/// must hide the view rather than fight it.
fn desired_browser_view(model : Model) -> Int32? {
  let conversation_screen = model.screen is Chat || model.screen is Codex
  let git_details_open = match model.screen {
    Chat => model.git_details_open
    Codex => model.codex.git_details_open()
    Skills | Schedules | Settings => false
  }
  guard model.is_desktop &&
    conversation_screen &&
    model.right_panel_open &&
    !model.right_panel_menu_open &&
    !model.dock_tab_menu_open &&
    model.select_menu is None &&
    !git_details_open &&
    !covering_overlay(model) else {
    return None
  }
  guard @dock.active_browser(model.dock) is Some(id) &&
    @preview.page(model.preview, id) is Some(page) &&
    page.url is Some(_) else {
    return None
  }
  Some(id)
}

///|
fn browser_geometry(model : Model) -> BrowserGeometry {
  {
    desired: desired_browser_view(model),
    sidebar_open: model.sidebar_open,
    narrow: model.narrow,
    terminal_open: model.terminal.is_open(),
    right_panel_expanded: model.right_panel_expanded,
    tree_layout: model.tree_layout,
  }
}

///|
/// Reconcile the native view with the pane after every message. Hiding is
/// immediate; showing waits for a fresh pane measurement (the measured
/// rectangle comes back as `BrowserPaneMeasured`, which sends the bounds
/// and then the visibility flip). The geometry signature keeps this pass
/// from re-measuring when nothing placement-relevant changed — including
/// after the measurement message itself, which never alters the signature.
fn sync_browser_view(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> (Model, @cmd.Cmd) {
  let pane = model.browser_pane
  match desired_browser_view(model) {
    None =>
      match pane.shown {
        Some(old) =>
          (
            { ..model, browser_pane: { shown: None, rect: None, geo: None, }, },
            browser_set_visible(dispatch, old, false),
          )
        None =>
          if pane.geo is Some(_) {
            // A measurement was requested but the view left the screen
            // before it landed; forget it so a later show re-measures.
            (
              {
                ..model,
                browser_pane: { shown: None, rect: None, geo: None, },
              },
              @cmd.none,
            )
          } else {
            (model, @cmd.none)
          }
      }
    Some(_) => {
      let geo = browser_geometry(model)
      if pane.geo is Some(measured) && measured == geo {
        (model, @cmd.none)
      } else {
        (
          { ..model, browser_pane: { ..pane, geo: Some(geo), }, },
          @cmd.batch([
            watch_browser_pane(dispatch),
            measure_browser_pane(dispatch),
          ]),
        )
      }
    }
  }
}

///|
/// Replace a selected record that disappeared while it was active or loading,
/// returning to an existing New chat draft or the supplied fresh id. The
/// removed record's composer state ends with it. List replies and identity
/// notifications share this transition because either can win their delivery
/// race.
fn replace_removed_selection(
  model : Model,
  channel : @interop.ChannelId,
  session : String,
  fresh_session : String,
  workspace : @common.Uri,
  record : ConversationRecord,
) -> Model {
  guard channel == model.focused &&
    model.conversation_selection() is Some(selected) &&
    selected.matches_record(channel, session, workspace, record) &&
    model.conversations
    .iter()
    .find_first(conv => {
      conv.device == channel &&
      conv.session_id == session &&
      conv.project() == workspace &&
      conv.is_archived_read_only() == (record is ArchivedRecord)
    })
    is Some(_) else {
    return model
  }
  let conversations = model.conversations.filter(conv => {
    conv.device != channel ||
    conv.session_id != session ||
    conv.project() != workspace ||
    conv.is_archived_read_only() != (record is ArchivedRecord)
  })
  let fallback = conversations
    .rev_iter()
    .find_first(conv => {
      conv.device == channel &&
      conv.project() == workspace &&
      model.conversation_is_new_chat(conv) &&
      conv.worth_keeping()
    })
  let fallback_session = match fallback {
    Some(draft) => draft.session_id
    None => fresh_session
  }
  let activated = { ..model, conversations, }
    .activate(channel, fallback_session, workspace)
    .with_active_project(Some(workspace))
  let activated = match fallback {
    Some(_) => activated
    None =>
      match activated.active_conversation() {
        Some(fresh) =>
          activated.replace_conversation({
            ..fresh,
            worktree_mode: model.default_worktree_mode(channel, workspace),
          })
        None => activated
      }
  }
  {
    ..activated,
    screen: Chat,
    loading_conversation: None,
    conversation_load_failure: None,
  }
}

///|
fn update(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  let previous = model
  let (cmd, model) = update_msg(dispatch, msg, model)
  let model = {
    ..model,
    management_return: if model.screen.work_screen() is Some(_) {
      None
    } else {
      match previous.screen.work_screen() {
        Some(origin) => Some(origin)
        None => previous.management_return
      }
    },
  }
  // The native dialog must not cover the desktop's connection-lost screen.
  // Detaching a workspace or losing its device also dismisses it.
  let model = {
    ..model,
    workspace_settings_dialog: model.workspace_settings_dialog.filter(dialog => {
      !(model.is_desktop && model.bridge_state() is BridgeLost(_)) &&
      model
      .device_state(dialog.target.channel)
      .map_or(false, dev => dev.projects.contains(dialog.target.workspace))
    }),
  }
  // A retained selection is not a read receipt when a panel covers it.
  // Reconcile after every transition, including panel restore and resize.
  let model = model.mark_visible_conversation_read()
  let notification_badge_cmd = notification_badge_command(
    previous,
    model,
    msg is Init,
  )
  let composer_context_changed = model.active_session != previous.active_session ||
    model.focused != previous.focused ||
    model.screen != previous.screen
  let model = if composer_context_changed {
    {
      ..model,
      composer_context_generation: previous.composer_context_generation + 1,
      select_menu: None,
    }
  } else {
    model
  }
  // Manual popovers sit above ordinary fixed backdrops in the browser's top
  // layer, so a newly covering surface must retire the root-owned select.
  let model = if !covering_overlay(previous) && covering_overlay(model) {
    { ..model, select_menu: None, }
  } else {
    model
  }
  // A registry refresh can retire the title control without changing the
  // active session. Do not leave its root menu flag hiding a native Browser
  // view after the control itself has disappeared.
  let model = if model.select_menu is Some(ProjectMenu) &&
    !model.can_choose_new_chat_project() {
    { ..model, select_menu: None, project_menu_query: "", }
  } else {
    model
  }
  // The query has meaning only while its exact menu is open. Context changes,
  // covering overlays, and selections close menus in several handlers; keep
  // all of those paths from reviving an old filter on the next fresh draft.
  let model = if model.select_menu is Some(ProjectMenu) ||
    model.project_menu_query.is_empty() {
    model
  } else {
    { ..model, project_menu_query: "", }
  }
  // On the narrow layout the sidebar is a full-screen drawer, so any
  // navigation that lands somewhere else — switching or creating a
  // conversation, opening Skills or Settings — closes it; centralizing the
  // rule here keeps every navigation handler drawer-agnostic.
  let model = if model.narrow &&
    model.sidebar_open &&
    (
      model.active_session != previous.active_session ||
      model.focused != previous.focused ||
      model.screen != previous.screen
    ) {
    { ..model, sidebar_open: false, }
  } else {
    model
  }
  // The sidebar lists one kind of conversation at a time, so a conversation
  // arriving on screen by any route — a click, Cmd+N, a toast, a restored
  // session — brings its own list with it. The stamp makes this an edge: the
  // header switch can browse the other list while the conversation stays up.
  let model = match model.sidebar_activation() {
    Some((sidebar_mode, _)) as revealed if revealed != model.sidebar_revealed =>
      { ..model, sidebar_mode, sidebar_revealed: revealed, }
    _ => model
  }
  let sidebar_mode_cmd = if model.sidebar_mode != previous.sidebar_mode {
    save_sidebar_mode(model.sidebar_mode)
  } else {
    @cmd.none
  }
  // The quick pick belongs to the focused conversation captured when it
  // opened, and to that conversation's concrete root. Both can change through
  // many messages — device/session switches, background pushes, connection
  // metadata, restored session data, a worktree registry broadcast — so the
  // package fences the palette once here rather than in every branch.
  let (quick_open_cmd, quick_open) = match model.active_checkout() {
    Some(active) =>
      model.quick_open.reconcile(
        dispatch.map(msg => QuickOpen(msg)),
        model.quick_open_input(active),
      )
    // No checkout on screen is no owner to fence against — the palette has
    // nothing left to search, so it closes here for the same reason it does
    // when its conversation is replaced.
    None => model.quick_open.close()
  }
  let model = { ..model, quick_open, }
  // The composer's git popover belongs to the checkout that was on screen,
  // and is fenced the same way and for the same reason. It cannot rely on its
  // click-away listener here: a switch by keyboard — Cmd+N, Quick Open — makes
  // no click at all, and neither does a checkout losing its repository under
  // it. Left standing the flag would spring the popover open on the
  // conversation arriving, once its branch probe answered, and meanwhile keep
  // `desired_browser_view` hiding the native browser with no chip on screen to
  // click — a blank pane with nothing to explain it.
  //
  // The second clause is the invariant rather than a list of paths: no chip,
  // no popover, however the branch came to be gone.
  let model = if model.git_details_open &&
    (
      model.active_session != previous.active_session ||
      model.focused != previous.focused ||
      !(model.active_conversation() is Some(conv) && conv.shows_git_chip())
    ) {
    { ..model, git_details_open: false, }
  } else {
    model
  }
  // Panel visibility is root-owned because it controls both HTML layout and
  // host-backed editor/browser lifecycles. Reconcile every transition once
  // here, no matter which semantic action opened or closed the panel.
  let panel_visibility_changed = model.right_panel_open !=
    previous.right_panel_open
  // Resolved replies call `show_editor_at` before this reconciliation. A valid
  // open already mounts the Viewer and either shows the cached document or
  // starts its generation-tagged read, including when the same TabLoading
  // document existed before the message. Activating it again here would start
  // a second untagged read. Failed/out-of-workspace opens retain an error and
  // still take the generic path so an older active document is restored.
  let file_opened_with_panel = !previous.right_panel_open &&
    model.right_panel_open &&
    msg.opens_file_before_panel_reconciliation() &&
    model.file_panel.error is None &&
    @dock.active_file(model.dock) is Some(_)
  let (panel_visibility_cmd, model) = if panel_visibility_changed &&
    !file_opened_with_panel {
    let (command, file_panel) = @fileeditor.panel_toggle_cmds(
      dispatch.map(msg => FileEditor(msg)),
      model.file_panel,
      file_ctx(model),
      opening=model.right_panel_open,
    )
    (command, { ..model, file_panel, })
  } else {
    (@cmd.none, model)
  }
  // Codex owns its Git popover flag, while the shell owns screen selection.
  // Leaving Codex closes the surface here so returning later cannot reopen a
  // popover for a task that is no longer the visible conversation.
  let model = if !(model.screen is Codex) && model.codex.git_details_open() {
    { ..model, codex: model.codex.with_git_details_closed(), }
  } else {
    model
  }
  let ctx = file_ctx(model)
  let owns_panel = model.file_panel.owner == Some(ctx.owner)
  let checkout = ctx.placement
    .bind(placement => placement.checkout_root())
    .map(root => {
      let previous = model.github.scope.filter(checkout => {
        checkout.channel == ctx.owner.channel && checkout.cwd == root.path
      })
      @github.CheckoutScope::{
        channel: ctx.owner.channel,
        cwd: root.path,
        head: if owns_panel {
          model.file_panel.git_actual_head
        } else {
          previous.bind(checkout => checkout.head)
        },
        branch: match (owns_panel, model.file_panel.git_graph) {
          (true, GitGraphReady(snapshot~, ..)) => snapshot.branch
          _ => previous.bind(checkout => checkout.branch)
        },
      }
    })
  let github_visible = model.file_panel_visible() &&
    model.devices.any(dev => {
      dev.channel == ctx.owner.channel &&
      dev.bridge is Connected &&
      dev.reconnect_failures == 0
    })
  let (github_cmd, github) = @github.reconcile(
    dispatch.map(msg => Github(msg)),
    model.github,
    checkout,
    github_visible && model.dock.active is Some(Github),
    review_active=github_visible &&
      ctx.panel_open &&
      ctx.active_history_diff is None &&
      ctx.active_file
      .bind(path => model.file_panel.docs.get(path))
      .bind(doc => doc.review)
      is Some(_),
    review_busy=model.file_panel.github_review.busy &&
      model.file_panel.github_review.checkout == checkout,
  )
  let model = { ..model, github, }
  let (model, panel_cmd) = sync_file_panel(dispatch, model)
  let model = {
    ..model,
    pending_review_context: model.pending_review_context.filter(pending => {
      pending.is_current(model)
    }),
  }
  // The launcher menu belongs to one dock owner. Conversation changes are
  // already explicit root transitions, so close it here instead of observing a
  // rendered owner marker through the DOM.
  let model = if model.right_panel_menu_open &&
    model.dock.owner != previous.dock.owner {
    { ..model, right_panel_menu_open: false, }
  } else {
    model
  }
  // Terminal input changes are reconciled as part of the root transition.
  // Host transport installation is declared separately by the root
  // subscriptions, so terminal reconciliation owns only terminal state.
  let terminal_emit = dispatch.map(msg => Terminal(msg))
  let terminal_input = model.terminal_input()
  let (terminal, terminal_cmd) = model.terminal.reconcile(
    terminal_emit, terminal_input,
  )
  let model = { ..model, terminal, }
  let owner = model.jobs_owner()
  let active = model.file_panel_visible() &&
    model.dock.active is Some(Jobs) &&
    owner is Some(owner) &&
    model.devices.any(dev => {
      dev.channel == owner.channel &&
      dev.bridge is Connected &&
      dev.reconnect_failures == 0
    })
  let (jobs_cmd, jobs) = @jobs.reconcile(
    dispatch.map(msg => Jobs(msg)),
    model.jobs,
    owner,
    active,
  )
  let model = { ..model, jobs, }
  let (preview, reloads) = model.preview.take_file_reloads()
  let model = { ..model, preview, }
  let preview_cmd = @cmd.batch(
    reloads.filter_map(id => {
      @preview.page(preview, id)
      .bind(page => page.url)
      .map(url => {
        browser_op(dispatch, @commands.browser_reload, { id, }, quiet=false, on_error=message => {
          Preview(@preview.ReloadFailed(id~, url~, message~))
        })
      })
    }),
  )
  let (annotation_cmd, model) = reconcile_browser_annotation(dispatch, model)
  let (model, browser_cmd) = sync_browser_view(dispatch, model)
  (
    @cmd.batch([
      cmd,
      notification_badge_cmd,
      sidebar_mode_cmd,
      quick_open_cmd,
      panel_visibility_cmd,
      panel_cmd,
      terminal_cmd,
      jobs_cmd,
      github_cmd,
      browser_cmd,
      preview_cmd,
      annotation_cmd,
      if msg is Dock(TabClosed(_)) {
        focus_dock_after_render()
      } else {
        @cmd.none
      },
      sync_dock_visibility(
        model.dock.active != previous.dock.active ||
        model.dock.tabs != previous.dock.tabs ||
        model.dock.owner != previous.dock.owner ||
        panel_visibility_changed ||
        msg.opens_file_before_panel_reconciliation() ||
        msg is Dock(TabActivated(_)),
      ),
    ]),
    model,
  )
}

///|
/// Only the resolved editor reply opens a document during this transition.
/// Every file selection first asks the host to classify the path.
fn Msg::opens_file_before_panel_reconciliation(self : Msg) -> Bool {
  self is OpenPathResolved(_, Editor(_))
}

///|
fn close_dock_tabs(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  selection : @dock.CloseSelection,
) -> (@cmd.Cmd, Model) {
  let tabs = @dock.tabs_to_close(model.dock, selection)
  guard !tabs.is_empty() else { return (@cmd.none, model) }
  let active = model.dock.active
  let commands : Array[@cmd.Cmd] = []
  let mut next = model
  // Close background tabs first so the active tab does not promote and mount
  // another tab that this same action is about to close. Routing every close
  // through the ordinary transition preserves document and browser teardown.
  for tab in tabs {
    if Some(tab) != active {
      let (command, updated) = update_msg(dispatch, Dock(TabClosed(tab)), next)
      commands.push(command)
      next = updated
    }
  }
  if active is Some(tab) && tabs.contains(tab) {
    let (command, updated) = update_msg(dispatch, Dock(TabClosed(tab)), next)
    commands.push(command)
    next = updated
  }
  // The menu disappears before its command runs. Keep subsequent keyboard
  // actions in the dock rather than leaving focus on the document body.
  commands.push(focus_dock_after_render())
  (
    @cmd.batch(commands),
    {
      ..next,
      right_panel_open: true,
      right_panel_menu_open: false,
      // Closing the final tab resets the panel in the ordinary close path.
      // Bulk close keeps the launcher open, so retain the user's chosen size.
      right_panel_expanded: model.right_panel_expanded,
    },
  )
}

///|
fn update_msg(
  dispatch : @cmd.Emit[Msg],
  msg : Msg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  match msg {
    Init => {
      // Both pages boot the same console; they differ only in where its
      // device comes from. A browser console asks the relay who is signed
      // in, and its connection and session rotation wait for the first
      // roster (`apply_roster`) because there is no channel to install before
      // sign-in. The desktop window owns its host outright, so its device is
      // already in place and it rotates the session at once. Component
      // subscriptions own their transcript and terminal DOM lifetimes.
      let device = if model.is_desktop {
        rotate_session(dispatch, model.focused)
      } else {
        fetch_console_me(dispatch)
      }
      (
        @cmd.batch([
          device,
          load_saved_settings(is_desktop=model.is_desktop, dispatch),
          watch_color_scheme(dispatch, model.is_desktop),
          request_sidebar_resize_mount(),
          measure_scrollbar_lane(),
        ]),
        model,
      )
    }
    Console(msg) => update_console_msg(dispatch, msg, model)
    LanguageLoaded(preference, languages) => {
      let language = preference.unwrap_or(@i18n.Preference::System)
      let locale = language.resolve(languages)
      (
        apply_language(is_desktop=model.is_desktop, dispatch, locale),
        { ..model, language, locale, },
      )
    }
    LanguageChanged(value, languages) => {
      guard @i18n.Preference::parse(value) is Some(language) else {
        return (@cmd.none, model)
      }
      let locale = language.resolve(languages)
      (
        @cmd.batch([
          apply_language(is_desktop=model.is_desktop, dispatch, locale),
          save_language(is_desktop=model.is_desktop, language, dispatch),
        ]),
        { ..model, language, locale, select_menu: None, },
      )
    }
    LanguageStorageFailed(message) =>
      // Report the failure without discarding the working in-memory choice.
      model.notify_error(
        dispatch,
        @settings.text(model.locale, LanguageStorageFailed(message)),
      )
    SystemLanguagesChanged(languages) => {
      let locale = model.language.resolve(languages)
      (
        apply_language(is_desktop=model.is_desktop, dispatch, locale),
        { ..model, locale, },
      )
    }
    SettingsLoaded(
      notification_corner~,
      tree_layout~,
      theme~,
      font_size~,
      fps_overlay_enabled~,
      minimal_transcript~,
      model=stored,
      conversation_models=remembered,
      agent~,
      codex_model~,
      codex_effort~,
      openseek_effort~,
      glm_effort~
    ) => {
      let theme = theme
        .map(value => Theme::parse(value, model.theme))
        .unwrap_or(model.theme)
      let app_font_size = font_size
        .map(value => AppFontSize::parse(value, model.app_font_size))
        .unwrap_or(model.app_font_size)
      // Startup runs before any conversation exists, so adopting the stored
      // tiers here is enough — every conversation minted afterwards reads
      // them.
      let default_model = stored
        .bind(value => EngineModel::parse(value))
        .unwrap_or(model.default_model)
      let default_agent = agent
        .bind(AgentChoice::parse)
        .unwrap_or(model.default_agent)
      let openseek_reasoning = openseek_effort
        .bind(OpenSeekReasoning::parse)
        .unwrap_or(model.openseek_reasoning)
      let glm_reasoning = glm_effort
        .bind(OpenSeekReasoning::parse)
        .unwrap_or(model.glm_reasoning)
      // The stored Codex pick seeds Codex's own selection state. When the
      // catalog arrives, `with_models` keeps this id if it is still listed
      // and otherwise falls back to the catalog default — exactly the
      // semantics a stale stored preference should have.
      let (codex_cmd, codex) = if codex_model is Some(codex_model) &&
        !codex_model.is_blank() {
        @codex.update(
          locale=model.locale,
          dispatch.map(msg => Codex(channel=model.focused, msg)),
          @codex.Msg::model_changed(codex_model.trim().to_owned()),
          model.codex,
          model.focused,
          url => open_external_link(dispatch, url),
        )
      } else {
        (@cmd.none, model.codex)
      }
      let (codex_effort_cmd, codex) = if codex_effort is Some(codex_effort) &&
        !codex_effort.is_blank() {
        @codex.update(
          locale=model.locale,
          dispatch.map(msg => Codex(channel=model.focused, msg)),
          @codex.Msg::effort_changed(codex_effort.trim().to_owned()),
          codex,
          model.focused,
          url => open_external_link(dispatch, url),
        )
      } else {
        (@cmd.none, codex)
      }
      let next = {
        ..model,
        notification_corner: notification_corner
        .map(NotificationCorner::parse)
        .unwrap_or(model.notification_corner),
        tree_layout: tree_layout
        .map(@fileeditor.TreeLayout::parse)
        .unwrap_or(model.tree_layout),
        theme,
        app_font_size,
        fps_overlay_enabled,
        minimal_transcript,
        default_model,
        default_agent,
        conversation_models: remembered
        .map(parse_conversation_models)
        .unwrap_or([]),
        openseek_reasoning,
        glm_reasoning,
        codex,
      }
      // The localStorage read and the host settings request start together.
      // If the host won that race, reconcile the just-loaded model preference
      // now; otherwise `HostSettingsLoaded` performs the same fold later.
      let next = if next.host_settings_loaded() {
        next.align_fresh_conversation_with_provider()
      } else {
        next
      }
      (
        @cmd.batch([
          theme.apply(model.system_dark, model.is_desktop, dispatch),
          app_font_size.apply(),
          codex_cmd,
          codex_effort_cmd,
        ]),
        next,
      )
    }
    // The host's settings, from the bridge-time `settings.get` or a peer's
    // edit broadcast. Revisions order concurrent clients and RPC replies;
    // while this page has optimistic writes, keep only the newest status and
    // apply it once the last write settles.
    CodexComposerAction(action) =>
      match action {
        @composer.ModelMenuToggled(identity~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          update_msg(dispatch, ToggleSelectMenu(CodexModelMenu), model)
        }
        @composer.ReasoningMenuToggled(identity~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          update_msg(dispatch, ToggleSelectMenu(CodexReasoningMenu), model)
        }
        @composer.SelectMenuDismissed(identity~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          update_msg(dispatch, CloseSelectMenu, model)
        }
        @composer.ModelSelected(identity~, value~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          update_msg(dispatch, ModelPicked(value), model)
        }
        @composer.ReasoningSelected(identity~, value~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          update_msg(dispatch, CodexEffortPicked(value), model)
        }
        @composer.ReviewChangesOpened(identity~, selection~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          open_review_context(dispatch, model, selection)
        }
        @composer.MentionOpened(identity~, mention~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          if mention.ref_ is @mention_context.SemanticSearch(_) {
            return open_semantic_selection(dispatch, model)
          }
          guard @mention_context.target(mention.ref_) is Some(target) else {
            return (@cmd.none, model)
          }
          let range = if mention.range is Some(_) {
            mention.range
          } else {
            target.range
          }
          request_open_path(
            dispatch,
            model,
            target.file,
            range,
            annotation?=target.annotation,
          )
        }
        @composer.FileIndexEnsured(identity~) => {
          guard model.screen is Codex &&
            model.codex.accepts_composer_identity(identity, model.focused) else {
            return (@cmd.none, model)
          }
          update_msg(dispatch, FileEditor(@fileeditor.EnsureFileIndex), model)
        }
        _ => {
          let channel = model.focused
          let (command, codex) = @codex.update(
            locale=model.locale,
            dispatch.map(next => Codex(channel~, next)),
            @codex.Msg::composer_action(action),
            model.codex,
            channel,
            url => open_external_link(dispatch, url),
          )
          (command, { ..model, codex, })
        }
      }
    ComposerAction(action) =>
      match action {
        @composer.ModelMenuToggled(..)
        | @composer.ReasoningMenuToggled(..)
        | @composer.SelectMenuDismissed(..)
        | @composer.ModelSelected(..)
        | @composer.ReasoningSelected(..)
        | @composer.ApprovalAnswered(..)
        | @composer.CodexRequestAnswerChanged(..)
        | @composer.CodexRequestResponded(..)
        | @composer.PermissionMenuToggled(..)
        | @composer.PermissionMenuDismissed(..)
        | @composer.PermissionSelected(..)
        | @composer.GitDetailsToggled(..)
        | @composer.WorktreeModeToggled(..)
        | @composer.ApiSetupRequested(..)
        | @composer.QueuedInputEditRequested(..)
        | @composer.QueuedInputSteerRequested(..)
        | @composer.QueuedInputDeleteRequested(..)
        | @composer.WorktreePlacementRetried(..)
        | @composer.MissingWorktreeRebuildRequested(..)
        | @composer.MissingWorktreeArchiveRequested(..) => {
          let identity = action.identity()
          guard model.screen is Chat &&
            model.conversation_for_composer_action(identity) is Some(conv) &&
            conv.device == model.focused &&
            conv.session_id == model.active_session else {
            return (@cmd.none, model)
          }
          match action {
            @composer.ModelMenuToggled(..) =>
              update_msg(dispatch, ToggleSelectMenu(OpenSeekModelMenu), model)
            @composer.ReasoningMenuToggled(..) =>
              update_msg(
                dispatch,
                ToggleSelectMenu(OpenSeekReasoningMenu),
                model,
              )
            @composer.SelectMenuDismissed(..) =>
              update_msg(dispatch, CloseSelectMenu, model)
            @composer.ModelSelected(value~, ..) =>
              update_msg(dispatch, ModelPicked(value), model)
            @composer.ReasoningSelected(value~, ..) =>
              update_msg(dispatch, OpenSeekEffortPicked(value), model)
            @composer.ApprovalAnswered(allow~, ..) =>
              update_msg(dispatch, ApprovalAnswered(allow~), model)
            @composer.GitDetailsToggled(..) =>
              update_msg(dispatch, ToggleGitDetails, model)
            @composer.WorktreeModeToggled(..) =>
              update_msg(dispatch, ToggleWorktreeMode, model)
            @composer.ApiSetupRequested(..) =>
              update_msg(dispatch, OpenApiSetup, model)
            @composer.QueuedInputEditRequested(id~, ..) => {
              // The composer is frozen while a large semantic selection is
              // written for a submitted draft; loading a queued message over
              // that draft would lose it and retarget the send.
              guard conv.run is Open(stage~, ..) &&
                !(stage is Cancelling) &&
                conv.pending_semantic_submission is None &&
                conv.queued_inputs.search_by(item => item.id == id)
                is Some(index) else {
                return (@cmd.none, model)
              }
              let item = conv.queued_inputs[index]
              (
                @cmd.none,
                model.replace_conversation({
                  ..conv,
                  task: editable_text(item.content),
                  images: item.images,
                  mentions: [],
                  composer_draft_present: true,
                  queue_edit_id: Some(id),
                }),
              )
            }
            @composer.QueuedInputSteerRequested(id~, ..) => {
              guard conv.run is Open(run_id~, stage~) && !(stage is Cancelling) else {
                return (@cmd.none, model)
              }
              guard conv.queued_inputs.search_by(item => item.id == id)
                is Some(index) &&
                !conv.pending_steers.any(input => input.submission_id == id) else {
                return (@cmd.none, model)
              }
              let item = conv.queued_inputs[index]
              let conv = conv.enqueue_steer(
                id,
                Some(run_id),
                item.content,
                editable_text(item.content),
                [],
                FollowupSteer,
                images=item.images,
              )
              (
                queue_openseek(
                  locale=model.locale,
                  dispatch,
                  conv.device,
                  conv.session_id,
                  @protocol.QueueSteer(id~),
                  run_id,
                ),
                model.replace_conversation(conv),
              )
            }
            @composer.QueuedInputDeleteRequested(id~, ..) => {
              guard conv.run is Open(run_id~, stage~) && !(stage is Cancelling) else {
                return (@cmd.none, model)
              }
              let editing = conv.queue_edit_id is Some(queued_id) &&
                queued_id == id
              // The edit being prepared for sending still targets this row.
              if editing && conv.pending_semantic_submission is Some(_) {
                return (@cmd.none, model)
              }
              (
                queue_openseek(
                  locale=model.locale,
                  dispatch,
                  conv.device,
                  conv.session_id,
                  @protocol.QueueWithdraw(id~),
                  run_id,
                ),
                if editing {
                  model.replace_conversation({
                    ..conv,
                    task: "",
                    images: [],
                    mentions: [],
                    composer_draft_present: false,
                    queue_edit_id: None,
                  })
                } else {
                  model
                },
              )
            }
            @composer.WorktreePlacementRetried(..) =>
              update_msg(dispatch, RetryWorktreePlacement, model)
            @composer.MissingWorktreeRebuildRequested(..) =>
              update_msg(dispatch, RepairWorktree, model)
            @composer.MissingWorktreeArchiveRequested(..) =>
              update_msg(
                dispatch,
                ArchiveSession(conv.device, conv.session_id),
                model,
              )
            @composer.PermissionMenuToggled(..)
            | @composer.PermissionMenuDismissed(..)
            | @composer.PermissionSelected(..)
            | @composer.CodexRequestAnswerChanged(..)
            | @composer.CodexRequestResponded(..) => (@cmd.none, model)
            _ => (@cmd.none, model)
          }
        }
        @composer.DraftSubmitted(identity~, draft~)
        | @composer.FollowupSubmitted(identity~, draft~, ..) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          // The root model may already be preparing a large semantic snapshot
          // while the component still holds its previous local draft. Ignore
          // duplicate submit events until that preparation settles.
          if conv.pending_semantic_submission is Some(_) {
            return (@cmd.none, model)
          }
          let original_focus = model.focused
          let original_session = model.active_session
          // `Send` reads the selected conversation synchronously. Select the
          // action owner only for that update, then restore visible navigation
          // while retaining the targeted conversation's submission state.
          let target = {
            ..model.replace_conversation({
              ..conv,
              task: draft.task,
              images: draft.images,
              mentions: draft.mentions,
              composer_draft_present: true,
            }),
            focused: conv.device,
            active_session: conv.session_id,
          }
          let submit = match action {
            @composer.FollowupSubmitted(choice~, ..) => SendFollowup(choice)
            _ => Send
          }
          let (command, submitted) = update_msg(dispatch, submit, target)
          (
            command,
            {
              ..submitted,
              focused: original_focus,
              active_session: original_session,
            },
          )
        }
        @composer.DraftPresenceChanged(identity~, present~, cleared_source~) =>
          if model.conversation_for_composer_action(identity) is Some(conv) {
            let task = if !present &&
              cleared_source is Some(source) &&
              conv.task == source.task {
              ""
            } else {
              conv.task
            }
            let mentions = if !present &&
              cleared_source is Some(source) &&
              conv.mentions == source.mentions {
              []
            } else {
              conv.mentions
            }
            (
              @cmd.none,
              model.replace_conversation({
                ..conv,
                task,
                mentions,
                images: if !present &&
                  cleared_source is Some(source) &&
                  conv.images == source.images {
                  []
                } else {
                  conv.images
                },
                composer_draft_present: present,
              }),
            )
          } else {
            (@cmd.none, model)
          }
        @composer.ReviewChangesRemoved(identity~, selections~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let mut draft : @composer.Draft = {
            task: conv.task,
            mentions: conv.mentions,
            images: conv.images,
          }
          for selection in selections {
            draft = draft.with_review_changes(selection, adding=false)
          }
          (
            @cmd.none,
            model.replace_conversation({ ..conv, mentions: draft.mentions, }),
          )
        }
        @composer.ReviewChangesOpened(identity~, selection~) => {
          guard model.conversation_for_composer_action(identity) is Some(_) else {
            return (@cmd.none, model)
          }
          open_review_context(dispatch, model, selection)
        }
        @composer.RootMentionRemoved(identity~, mention~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          (
            @cmd.none,
            model.replace_conversation({
              ..conv,
              mentions: conv.mentions.filter(existing => {
                existing.ref_ != mention.ref_
              }),
            }),
          )
        }
        @composer.ShellCommandSubmitted(identity~, command~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          submit_shell_command(dispatch, model, conv, command)
        }
        @composer.ShellTerminalRequested(identity~, index~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) &&
            conv.shell_commands.get(index) is Some(pending) else {
            return (@cmd.none, model)
          }
          update_msg(
            dispatch,
            Terminal(@terminal.RevealCommand(shell=pending.id)),
            model,
          )
        }
        @composer.SlashCommand(identity~, command~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let (command, changed) = run_slash_command(
            dispatch,
            { ..model, focused: conv.device, active_session: conv.session_id, },
            command,
          )
          (
            command,
            {
              ..changed,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
        @composer.MentionOpened(identity~, mention~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let selected = {
            ..model,
            focused: conv.device,
            active_session: conv.session_id,
          }
          let (command, opened) = if mention.ref_
            is @mention_context.SemanticSearch(_) {
            open_semantic_selection(dispatch, selected)
          } else {
            guard @mention_context.target(mention.ref_) is Some(target) else {
              return (@cmd.none, model)
            }
            let range = if mention.range is Some(_) {
              mention.range
            } else {
              target.range
            }
            request_open_path(
              dispatch,
              selected,
              target.file,
              range,
              annotation?=target.annotation,
              return_to?=model.active_checkout().map(active => active.owner),
            )
          }
          (
            command,
            {
              ..opened,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
        @composer.GoalCancelled(identity~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          (@cmd.none, model.replace_conversation({ ..conv, goal_edit: None, }))
        }
        @composer.GoalEditStarted(identity~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let (command, changed) = update_msg(dispatch, OpenGoalEditor, {
            ..model,
            focused: conv.device,
            active_session: conv.session_id,
          })
          (
            command,
            {
              ..changed,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
        @composer.GoalCleared(identity~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let (command, changed) = update_msg(dispatch, ClearGoal, {
            ..model,
            focused: conv.device,
            active_session: conv.session_id,
          })
          (
            command,
            {
              ..changed,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
        @composer.GoalSubmitted(identity~, draft~, prompt_present~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          guard conv.goal_edit is Some(_) else { return (@cmd.none, model) }
          let target = {
            ..model.replace_conversation({
              ..conv,
              goal_edit: Some({ draft, }),
              composer_draft_present: prompt_present,
            }),
            focused: conv.device,
            active_session: conv.session_id,
          }
          let (command, submitted) = update_msg(dispatch, SubmitGoal, target)
          (
            command,
            {
              ..submitted,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
        @composer.FileIndexEnsured(identity~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let (command, indexed) = update_msg(
            dispatch,
            FileEditor(@fileeditor.EnsureFileIndex),
            { ..model, focused: conv.device, active_session: conv.session_id, },
          )
          (
            command,
            {
              ..indexed,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
        @composer.StopRequested(identity~) => {
          guard model.conversation_for_composer_action(identity) is Some(conv) else {
            return (@cmd.none, model)
          }
          let (command, stopped) = update_msg(dispatch, Stop, {
            ..model,
            focused: conv.device,
            active_session: conv.session_id,
          })
          (
            command,
            {
              ..stopped,
              focused: model.focused,
              active_session: model.active_session,
            },
          )
        }
      }
    JumpToLocation(path~, range~, annotation~) =>
      request_open_path(dispatch, model, path, range, annotation?)
    TranscriptReviewChangesOpened(slot~, selection~) => {
      guard model.transcript_slot().map(active => active.key()) == Some(slot) else {
        return (@cmd.none, model)
      }
      open_review_context(dispatch, model, selection)
    }
    // Intercepted here rather than delegated to the fileeditor package: the
    // comment becomes an annotation chip on the composer draft, which only
    // this model knows about. `quote`/`range` come from the panel's viewer.
    FileEditor(@fileeditor.ReviewContextRevealFinished(source~, found=false)) => {
      guard model.file_panel.review_context_reveal is Some(selection) &&
        selection.source == source else {
        return (@cmd.none, model)
      }
      let (command, panel) = @fileeditor.update(
        dispatch.map(msg => FileEditor(msg)),
        @fileeditor.ReviewContextRevealFinished(source~, found=false),
        model.file_panel,
        file_ctx(model),
      )
      let (notice, next) = { ..model, file_panel: panel, }.notify_error(
        dispatch, "These saved changes no longer match the current review or are hidden by its filters. The saved context is unchanged.",
      )
      (@cmd.batch([command, notice]), next)
    }
    FileEditor(@fileeditor.ReviewContextChanged(owner~, selection~, adding~)) => {
      guard file_ctx(model).owner == owner &&
        model.file_panel.accepts_review_context(selection) else {
        return (@cmd.none, model)
      }
      if model.screen is Codex {
        return (
          @cmd.none,
          {
            ..model,
            codex: model.codex.with_review_changes(selection, adding~),
          },
        )
      }
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      let draft : @composer.Draft = {
        task: conv.task,
        mentions: conv.mentions,
        images: conv.images,
      }
      (
        @cmd.none,
        model.replace_conversation({
          ..conv,
          mentions: draft.with_review_changes(selection, adding~).mentions,
        }),
      )
    }
    FileEditor(
      EditorCommentAdded(
        resource~,
        file~,
        range~,
        quote~,
        comment~,
        feedback_id~
      )
    ) => {
      if model.screen is Codex {
        // Codex owns a separate wire model, but the visible editor annotation
        // is the same structured chip as OpenSeek's. Keep it in Codex's shared
        // composer tray; never leak it into the hidden OpenSeek conversation.
        return (
          @fileeditor.remove_editor_feedback(resource, feedback_id),
          {
            ..model,
            codex: model.codex.with_editor_comment(
              file.0,
              range,
              comment,
              quote,
            ),
          },
        )
      }
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      let mentions = @composer.Draft::{
          images: conv.images,
          task: conv.task,
          mentions: conv.mentions,
        }.with_mention({
          ref_: Annotation(
            file=file.0,
            start_line=range.start_line_number,
            end_line=range.end_line_number,
            quote~,
            comment~,
            side=@mention_context.WorkingRevision,
          ),
          range: Some(range),
        }).mentions
      // The chip is the comment's carrier from here on; clearing the editor's
      // own bubble keeps the two from drifting apart (and from double-sending
      // if the user comments again).
      (
        @fileeditor.remove_editor_feedback(resource, feedback_id),
        model.replace_conversation({ ..conv, mentions, }),
      )
    }
    // The feedback service queues this after the comment-added message above,
    // so the new annotation is already in the visible composer batch. Reuse
    // each agent's normal submit path: an idle task starts, while a running
    // task receives the batch through its existing steer/message queue.
    FileEditor(@fileeditor.ApplyAllFeedback) =>
      match model.screen {
        Chat => update_msg(dispatch, Send, model)
        Codex => {
          let input = model.codex_composer_input()
          update_msg(
            dispatch,
            CodexComposerAction(
              @composer.DraftSubmitted(
                identity=input.identity,
                draft=input.draft,
              ),
            ),
            model,
          )
        }
        Skills | Schedules | Settings => (@cmd.none, model)
      }
    // Full-diff comments carry both line domains because a deletion has no
    // working-document position. Prefer the modified line for additions and
    // context; retain the original line for an original-only deletion. Only a
    // modified-side comment receives a concrete editor range, so reopening a
    // deleted-line chip cannot claim stale source columns.
    FileEditor(
      DiffCommentAdded(
        file~,
        original_line_number~,
        modified_line_number~,
        quote~,
        comment~,
        resource~,
        feedback_id~
      )
    ) => {
      let clear_feedback = match (resource, feedback_id) {
        (Some(resource), Some(feedback_id)) =>
          @fileeditor.remove_editor_feedback(resource, feedback_id)
        _ => @cmd.none
      }
      let (line_number, range, side) = match modified_line_number {
        Some(line_number) if line_number >= 1 => {
          let end_column = if quote.is_empty() { 1 } else { quote.length() + 1 }
          (
            line_number,
            Some(@common.Range(line_number, 1, line_number, end_column)),
            @mention_context.WorkingRevision,
          )
        }
        _ =>
          match original_line_number {
            Some(line_number) if line_number >= 1 =>
              (line_number, None, @mention_context.OriginalRevision)
            _ => return (clear_feedback, model)
          }
      }
      if model.screen is Codex {
        let end_column = if quote.is_empty() { 1 } else { quote.length() + 1 }
        let comment_range = range.unwrap_or(
          @common.Range(line_number, 1, line_number, end_column),
        )
        return (
          clear_feedback,
          {
            ..model,
            codex: model.codex.with_editor_comment(
              file.0,
              comment_range,
              comment,
              quote,
              side~,
            ),
          },
        )
      }
      guard model.active_conversation() is Some(conv) else {
        return (clear_feedback, model)
      }
      let mentions = @composer.Draft::{
          images: conv.images,
          task: conv.task,
          mentions: conv.mentions,
        }.with_mention({
          ref_: Annotation(
            file=file.0,
            start_line=line_number,
            end_line=line_number,
            quote~,
            comment~,
            side~,
          ),
          range,
        }).mentions
      (clear_feedback, model.replace_conversation({ ..conv, mentions, }))
    }
    // Search rows use the same ordinary positioned-open path as definition,
    // mention, and Quick Open navigation. An active picker is fulfilled in
    // place; an already-open file is activated.
    FileEditor(@fileeditor.SearchMatchSelected(path~, range~)) =>
      request_open_path(dispatch, model, path, Some(range))
    SemanticSelectionMaterialized(owner~, submission_id~, artifact~) => {
      guard model.find_conversation(owner.channel, owner.session) is Some(conv) &&
        conv.pending_semantic_submission is Some(pending) &&
        pending.submission_id == submission_id else {
        return (@cmd.none, model)
      }
      // The composer was frozen while the file was written, so the only
      // thing that can differ from the captured snapshot is the Search
      // explorer selection. Whatever changed becomes the next draft, beside
      // the newly submitted turn.
      let next_mentions = conv.mentions.filter(mention => {
        !pending.mentions.any(existing => existing.ref_ == mention.ref_)
      })
      // The captured draft is the value the user submitted. Replace only the
      // matching semantic mention in that snapshot; other mentions are kept
      // in their original order and later UI edits cannot change this send.
      let mentions = pending.mentions.map(mention => {
        if mention.ref_ is @mention_context.SemanticSearch(current) &&
          current == pending.reference {
          {
            ..mention,
            ref_: @mention_context.SemanticSearchArtifact(artifact),
          }
        } else {
          mention
        }
      })
      let target = model.replace_conversation({
        ..conv,
        task: pending.task,
        mentions,
        composer_draft_present: true,
        pending_semantic_submission: None,
      })
      let original_focus = model.focused
      let original_session = model.active_session
      let target = {
        ..target,
        focused: owner.channel,
        active_session: owner.session,
      }
      let submit = pending.followup
        .map(choice => SendFollowup(choice))
        .unwrap_or(Send)
      let (command, submitted) = update_msg(dispatch, submit, target)
      let submitted = if !next_mentions.is_empty() &&
        submitted.find_conversation(owner.channel, owner.session)
        is Some(sent_conv) {
        submitted.replace_conversation({
          ..sent_conv,
          mentions: next_mentions,
          composer_draft_present: true,
        })
      } else {
        submitted
      }
      (
        command,
        {
          ..submitted,
          focused: original_focus,
          active_session: original_session,
        },
      )
    }
    SemanticSelectionMaterializationFailed(owner~, submission_id~, message~) => {
      guard model.find_conversation(owner.channel, owner.session) is Some(conv) &&
        conv.pending_semantic_submission is Some(pending) &&
        pending.submission_id == submission_id else {
        return (@cmd.none, model)
      }
      // Failure ends this send attempt. The composer already shows the
      // user's latest selection; only the frozen snapshot is dropped.
      let (toast, model) = model.notify_error(
        dispatch,
        "Could not prepare semantic-search selection: \{message}",
      )
      (
        toast,
        model.replace_conversation({
          ..conv,
          pending_semantic_submission: None,
        }),
      )
    }
    FileEditor(@fileeditor.SemanticSelectionChanged(owner~, reference~)) => {
      // Codex owns a separate composer state from OpenSeek. The file editor
      // still emits one shared selection event, so route it to the selected
      // Codex task before looking for an OpenSeek conversation. The exact
      // owner fence prevents a delayed selection from retargeting a newly
      // selected task or a different device.
      if model.screen is Codex {
        guard owner.channel == model.focused &&
          model.codex.active_id() is Some(session) &&
          session == owner.session else {
          return (@cmd.none, model)
        }
        return (
          @cmd.none,
          { ..model, codex: model.codex.with_semantic_selection(reference), },
        )
      }
      guard model.active_conversation() is Some(conv) &&
        conv.device == owner.channel &&
        conv.session_id == owner.session else {
        return (@cmd.none, model)
      }
      let draft : @composer.Draft = {
        task: conv.task,
        mentions: conv.mentions,
        images: [],
      }
      (
        @cmd.none,
        model.replace_conversation({
          ..conv,
          mentions: draft.with_semantic_selection(reference).mentions,
        }),
      )
    }
    FileEditor(
      @fileeditor.OfficeSelectionChanged(
        owner~,
        epoch~,
        path~,
        sig~,
        selection~
      )
    ) => {
      guard model.file_panel.accepts_office_callback(
        file_ctx(model),
        owner,
        epoch,
        path,
        sig,
      ) else {
        return (@cmd.none, model)
      }
      offer_office_selection(dispatch, model, owner, selection)
    }
    FileEditor(@fileeditor.OfficeFeedbackSubmitted(preview, text, apply~)) => {
      guard model.file_panel.pending_office_selection(file_ctx(model)) ==
        Some(preview) &&
        owns_office_selection(model, preview.owner) &&
        !text.trim().is_empty() else {
        return (@cmd.none, model)
      }
      let (command, model) = confirm_office_selection(
        model,
        preview,
        comment=text,
      )
      if apply {
        let (send, model) = update_msg(
          dispatch,
          FileEditor(@fileeditor.ApplyAllFeedback),
          model,
        )
        (@cmd.batch([command, send]), model)
      } else {
        (command, model)
      }
    }
    FileEditor(@fileeditor.OfficeSelectionConfirmed(preview)) =>
      confirm_office_selection(
        model,
        preview,
        comment?=model.file_panel.office_selection_comment,
      )
    FileEditor(
      @fileeditor.PdfSelectionChanged(
        owner~,
        epoch~,
        path~,
        sig~,
        generation~,
        selection~
      )
    ) => {
      guard model.file_panel.accepts_pdf_callback(
        file_ctx(model),
        owner,
        epoch,
        path,
        sig,
        generation,
      ) else {
        return (@cmd.none, model)
      }
      offer_office_selection(dispatch, model, owner, selection)
    }
    // The host classifies tree selections before the dock opens their viewer.
    FileEditor(FileSelected(path~, ..)) =>
      request_open_path(dispatch, model, path.0, None)
    // A Changes row is the review action: open/activate the same ordinary file
    // tab, then let the file subsystem pair its working-tree document with the
    // row's HEAD path. Deleted rows have no working file but still use the
    // current path as their tab identity.
    FileEditor(ChangedFileSelected(change))
    | FileEditor(ChangedFileNavigated(change, _)) => {
      let placement = file_ctx(model).placement
      guard placement is Some(value) && value.is_ready() else {
        return (@cmd.none, model)
      }
      guard model.workspace_resource(change.path) is Some(resource) else {
        return (@cmd.none, model)
      }
      let model = model.begin_editor_navigation()
      let had_active = @dock.active_file(model.dock) is Some(_)
      let dock = if model.dock.active is Some(FilePicker) {
        @dock.resolve_pick(model.dock, File(path=resource))
      } else {
        @dock.open_file(model.dock, resource)
      }
      let model = { ..model, dock, }
      let (cmd, panel) = @fileeditor.open_changed_document(
        dispatch.map(msg => FileEditor(msg)),
        model.file_panel,
        file_ctx(model),
        change,
        had_active~,
      )
      let panel = match msg {
        FileEditor(ChangedFileNavigated(_, last)) =>
          panel.with_review_navigation_destination(
            file_ctx(model),
            change,
            last,
          )
        _ => panel
      }
      (cmd, { ..model, file_panel: panel, })
    }
    // Historical rows open immutable commit/path identities rather than
    // joining the ordinary filesystem tab projection.
    FileEditor(HistoricalFileSelected(diff)) => {
      let placement = file_ctx(model).placement
      guard placement is Some(value) && value.is_ready() else {
        return (@cmd.none, model)
      }
      let model = model.begin_editor_navigation()
      let dock = @dock.open_history_diff(model.dock, diff)
      let model = { ..model, dock, }
      let (cmd, panel) = @fileeditor.open_history_diff(
        dispatch.map(msg => FileEditor(msg)),
        model.file_panel,
        file_ctx(model),
        diff,
      )
      (cmd, { ..model, file_panel: panel, })
    }
    // Definition/reference jumps share file routing. Their original owner
    // stamp rejects a language reply that outlived a conversation switch.
    FileEditor(OpenNavigationLocation(owner~, path~, range~)) => {
      guard model.file_panel.owner is Some(panel_owner) &&
        panel_owner == owner &&
        file_ctx(model).owner == owner else {
        return (@cmd.none, model)
      }
      request_open_path(dispatch, model, path.0, Some(range))
    }
    // Definition/References providers live inside the imperative Viewer, but
    // their host failures belong on the app's ordinary toast rail. Fence the
    // callback by its original conversation and coalesce identical live
    // toasts: one user gesture can cause Viewer to ask more than once.
    FileEditor(@fileeditor.LanguageRequestFailed(owner~, message~)) => {
      guard model.file_panel.owner is Some(panel_owner) &&
        panel_owner == owner &&
        file_ctx(model).owner == owner else {
        return (@cmd.none, model)
      }
      if model.notifications.any(toast => toast.message == message) {
        (@cmd.none, model)
      } else {
        model.notify_error(dispatch, message)
      }
    }
    // Keep watcher lifecycle state in the file-editor package, but present an
    // accepted current-generation failure on the app-owned toast rail. The
    // before/after check uses that package's owner/root/generation fencing and
    // also prevents a repeated host notification from stacking duplicates.
    FileEditor(
      @fileeditor.FileWatchFailed(channel~, root~, generation~, message~)
    ) => {
      let file_message = @fileeditor.FileWatchFailed(
        channel~,
        root~,
        generation~,
        message~,
      )
      let (cmd, panel) = @fileeditor.update(
        dispatch.map(next => FileEditor(next)),
        file_message,
        model.file_panel,
        file_ctx(model),
      )
      let next = { ..model, file_panel: panel, }
      if panel.watch_error is Some(err) &&
        err == message &&
        model.file_panel.watch_error != Some(message) &&
        !model.notifications.any(toast => toast.message == message) {
        let (toast, next) = next.notify_error(dispatch, message)
        (@cmd.batch([cmd, toast]), next)
      } else {
        (cmd, next)
      }
    }
    QuickOpenOpen(provider) => open_quick_open(dispatch, model, provider)
    QuickOpen(msg) => update_quick_open(dispatch, model, msg)
    ToggleSelectMenu(menu) => {
      if menu is ProjectMenu && !model.can_choose_new_chat_project() {
        return (@cmd.none, model)
      }
      let select_menu = if model.select_menu is Some(open_menu) &&
        open_menu == menu {
        None
      } else {
        Some(menu)
      }
      (
        @cmd.none,
        {
          ..model,
          select_menu,
          project_menu_query: "",
          git_details_open: false,
          codex: model.codex.with_git_details_closed(),
        },
      )
    }
    CloseSelectMenu =>
      (@cmd.none, { ..model, select_menu: None, project_menu_query: "", })
    ProjectMenuQueryChanged(query) =>
      if model.select_menu is Some(ProjectMenu) &&
        model.screen is Chat &&
        model.composing_new_chat() {
        (@cmd.none, { ..model, project_menu_query: query, })
      } else {
        (@cmd.none, model)
      }
    ProjectMenuProjectChosen(workspace) => {
      let menu_open = model.select_menu is Some(ProjectMenu)
      let closed = { ..model, select_menu: None, project_menu_query: "", }
      guard menu_open &&
        model.can_choose_new_chat_project() &&
        @resource.belongs_to(workspace, model.focused) &&
        model.focused_device() is Some(dev) &&
        dev.projects.contains(workspace) &&
        model.active_conversation() is Some(active) else {
        return (@cmd.none, closed)
      }
      // The selected row is still actionable so keyboard and pointer behavior
      // are uniform, but choosing it must not rotate a second empty session.
      if active.project() == workspace {
        (@cmd.none, closed)
      } else {
        update_msg(dispatch, NewChatIn(model.focused, Some(workspace)), closed)
      }
    }
    ModelPicked(value) => {
      guard ModelChoice::parse(value) is Some(choice) else {
        return (@cmd.none, model)
      }
      let model = { ..model, select_menu: None, }
      match choice {
        OpenSeekModel(engine_model) =>
          if model.screen is Codex {
            // Only a composing draft's chip offers the OpenSeek group; the
            // pick hands the fresh conversation back to OpenSeek. The draft
            // is abandoned and a fresh OpenSeek chat rotates into the
            // draft's project (or whatever project is active when the draft
            // never resolved one).
            guard model.codex.composing_draft() else {
              return (@cmd.none, model)
            }
            let root = model.codex.new_thread_cwd()
            let (abandon_cmd, codex) = @codex.update(
              locale=model.locale,
              dispatch.map(msg => Codex(channel=model.focused, msg)),
              @codex.Msg::abandon_draft(),
              model.codex,
              model.focused,
              url => open_external_link(dispatch, url),
            )
            let next = {
              ..model,
              codex,
              default_model: engine_model,
              default_agent: OpenSeekAgent,
              loading_conversation: None,
            }
            let next = if !root.is_empty() &&
              @resource.of_path(model.focused, root) is Some(workspace) {
              next.with_active_project(Some(workspace))
            } else {
              next
            }
            (
              @cmd.batch([
                abandon_cmd,
                save_default_model(engine_model),
                save_default_agent(OpenSeekAgent),
                rotate_session(dispatch, next.focused),
              ]),
              next,
            )
          } else {
            // The selector changes the conversation on screen. The tier is
            // pinned to that conversation right away — a chat can be given a
            // tier and left unsent for days — and becomes what the next new
            // chat starts from. (Starting a run pins it too; see `Started`.)
            // A turn already in flight keeps the model it was started with;
            // this takes effect on the next.
            guard model.active_conversation() is Some(conv) else {
              return (@cmd.none, model)
            }
            let next = model
              .replace_conversation({ ..conv, engine_model, })
              .remember_model(conv.device, conv.session_id, engine_model)
            (
              @cmd.batch([
                save_default_model(engine_model),
                save_default_agent(OpenSeekAgent),
                save_conversation_model(
                  conversation_model_key(conv.device, conv.session_id),
                  engine_model,
                ),
              ]),
              {
                ..next,
                default_model: engine_model,
                default_agent: OpenSeekAgent,
              },
            )
          }
        CodexModel(id) => {
          let (model_cmd, codex) = @codex.update(
            locale=model.locale,
            dispatch.map(msg => Codex(channel=model.focused, msg)),
            @codex.Msg::model_changed(id),
            model.codex,
            model.focused,
            url => open_external_link(dispatch, url),
          )
          let persist = @cmd.batch([
            model_cmd,
            save_codex_model(id),
            save_default_agent(CodexAgent),
          ])
          if model.screen is Codex {
            // A pick within the Codex group: the next thread start or turn
            // uses it, on the draft and stored-thread surfaces alike.
            (persist, { ..model, codex, default_agent: CodexAgent, })
          } else {
            // Only a composing OpenSeek chat's chip offers the Codex group;
            // the pick hands the fresh conversation to Codex. One composing
            // row at a time: an empty husk that was only ever the "New chat"
            // placeholder is deactivated so its row vanishes with the
            // switch; a husk holding typed writing keeps its row (and the
            // text survives a switch back).
            guard model.composing_new_chat() &&
              model.active_conversation() is Some(conv) else {
              return (@cmd.none, model)
            }
            let cwd = @resource.path_for(conv.project(), model.focused).unwrap_or(
              "",
            )
            let active_session = if conv.worth_keeping() {
              model.active_session
            } else {
              ""
            }
            (
              @cmd.batch([
                persist,
                CodexDraftRotation::{ cwd, }.rotate(dispatch),
              ]),
              {
                ..model,
                codex,
                default_agent: CodexAgent,
                screen: Codex,
                active_session,
                sidebar_open: model.sidebar_open && !model.narrow,
              },
            )
          }
        }
        CodexUnavailablePick =>
          // The Codex group's placeholder row: not a model, a doorway.
          // Sign-in and connection state live in the Settings page's Codex
          // group.
          update_msg(dispatch, OpenSetup, model)
      }
    }
    CodexEffortPicked(value) => {
      let model = { ..model, select_menu: None, }
      let (effort_cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(msg => Codex(channel=model.focused, msg)),
        @codex.Msg::effort_changed(value),
        model.codex,
        model.focused,
        url => open_external_link(dispatch, url),
      )
      (
        @cmd.batch([effort_cmd, save_codex_reasoning_effort(value)]),
        { ..model, codex, },
      )
    }
    OpenSeekEffortPicked(value) => {
      guard OpenSeekReasoning::parse(value) is Some(reasoning) else {
        return (@cmd.none, model)
      }
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.engine_model is (Glm53 | Glm53Flash) {
        (
          reasoning.save_for_glm(),
          { ..model, glm_reasoning: reasoning, select_menu: None, },
        )
      } else {
        (
          reasoning.save(),
          { ..model, openseek_reasoning: reasoning, select_menu: None, },
        )
      }
    }
    MaxStepsChanged(value) => (@cmd.none, { ..model, max_steps: value, })
    SetupApiKeyChanged(value) => {
      guard model.host_settings_loaded() else { return (@cmd.none, model) }
      (@cmd.none, { ..model, setup_api_key: value, })
    }
    ProviderChanged(value) => {
      guard model.host_settings_loaded() else { return (@cmd.none, model) }
      let provider = ApiProvider::parse(value)
      // The update channel no longer derives from the chat provider (only
      // the hosted chat proxy was retired; self-update and the relay stay
      // on the SeekMoon origin), so a provider switch leaves the update
      // answer alone.
      let push = push_host_settings(
        dispatch,
        model.focused,
        provider_settings_patch(provider, model.custom_api_url),
        model.focused_connection_generation(),
      )
      let next = {
        ..model,
        api_provider: provider,
        custom_api_url: if provider is Custom &&
          model.custom_api_url == OpenRouterChatCompletionsUrl {
          ""
        } else {
          model.custom_api_url
        },
        setup_api_key: "",
        settings_saves: model.settings_saves + 1,
        select_menu: None,
      }.align_fresh_conversation_with_provider()
      // The switch can move the endpoint between usable and not. Inside the
      // setup modal the form simply re-renders for the new provider; a
      // switch that breaks a usable endpoint away from the Settings page
      // opens the modal — it is the announcement now, not a toast.
      (push, next.settle_api_setup())
    }
    FollowupBehaviorChanged(value) => {
      guard model.host_settings_loaded() else { return (@cmd.none, model) }
      let behavior = FollowupBehavior::parse(value)
      (
        push_host_settings(
          dispatch,
          model.focused,
          followup_behavior_patch(behavior),
          model.focused_connection_generation(),
        ),
        {
          ..model,
          followup_behavior: behavior,
          settings_saves: model.settings_saves + 1,
          select_menu: None,
        },
      )
    }
    CustomApiUrlChanged(value) => {
      guard model.host_settings_loaded() else { return (@cmd.none, model) }
      (
        push_host_settings(
          dispatch,
          model.focused,
          custom_url_settings_patch(value),
          model.focused_connection_generation(),
        ),
        {
          ..model,
          custom_api_url: value,
          settings_saves: model.settings_saves + 1,
        },
      )
    }
    NotificationCornerChanged(value) => {
      let corner = NotificationCorner::parse(value)
      (
        save_notification_corner(corner),
        { ..model, notification_corner: corner, select_menu: None, },
      )
    }
    TreeLayoutChanged(value) => {
      let layout = @fileeditor.TreeLayout::parse(value)
      // The dock flips purely in CSS, but the viewer cannot see its host
      // change size on its own — remeasure it (mount_cmds is idempotent and
      // carries the remeasure).
      (
        @cmd.batch([
          save_tree_layout(layout),
          @fileeditor.mount_cmds(dispatch.map(msg => FileEditor(msg))),
        ]),
        { ..model, tree_layout: layout, select_menu: None, },
      )
    }
    NotificationExpired(id) | DismissNotification(id) =>
      (
        @cmd.none,
        { ..model, notifications: model.notifications.filter(t => t.id != id), },
      )
    RemoteAccess(msg) => {
      let (remote_access, command) = @remote_access.update(
        model.remote_access,
        msg,
        dispatch.map(msg => RemoteAccess(msg)),
      )
      (command, { ..model, remote_access, })
    }
    AppInfoLoaded(version~, console_url~) =>
      (@cmd.none, { ..model, app_version: version, console_url, })
    CheckForUpdates =>
      // A user-initiated check; never stacks on an in-flight one, never
      // interrupts a download already underway, and never clobbers a staged
      // download waiting for its restart.
      if model.update_ux
        is (CheckingForUpdate
        | ConfirmingRestart(..)
        | DownloadingUpdate(..)
        | UpdateReady(..)
        | RestartingForUpdate(..)) {
        (@cmd.none, model)
      } else {
        (
          check_for_updates(dispatch, explicit=true),
          { ..model, update_ux: CheckingForUpdate, },
        )
      }
    UpdateCheckFinished(result~, explicit~) => {
      // A stale reply must not clobber a flow the user has since started
      // (confirming, downloading); only the waiting states accept results.
      guard model.update_ux
        is (UpdateUnknown
        | CheckingForUpdate
        | UpToDate
        | UpdateCheckFailed(..)) else {
        return (@cmd.none, model)
      }
      match result {
        CheckFound(version~, installable=true, ..) =>
          // An installable release downloads itself — restarting into it
          // stays the user's call.
          (
            download_update(dispatch),
            {
              ..model,
              update_ux: DownloadingUpdate(version~, progress={
                downloaded_bytes: 0,
                total_bytes: None,
              }),
            },
          )
        CheckFound(version~, installable=false, unavailable_reason~) => {
          let (cmd, next) = if unavailable_reason is Some(reason) {
            model.notify_error(dispatch, reason)
          } else {
            (@cmd.none, model)
          }
          (
            cmd,
            { ..next, update_ux: UpdateAvailable(version~, installable=false), },
          )
        }
        CheckUpToDate =>
          (
            @cmd.none,
            {
              ..model
              // Only worth stating when the user asked; a quiet startup
              // check leaves nothing behind.
              ,
              update_ux: if explicit {
                UpToDate
              } else {
                UpdateUnknown
              },
            },
          )
        CheckUnreachable(reason~) =>
          // Offline is routine for the app, an answer for the user.
          if explicit {
            (
              @cmd.none,
              {
                ..model,
                update_ux: UpdateCheckFailed(
                  message=notice_text(
                    model.locale,
                    UpdateServer(reason.to_string()),
                  ),
                ),
              },
            )
          } else {
            (@cmd.none, { ..model, update_ux: UpdateUnknown, })
          }
        CheckMalformed(reason~) =>
          // A garbage manifest also happens under captive portals, so the
          // app asking stays quiet (the host logged it); the user asking
          // gets the truth.
          if explicit {
            (
              @cmd.none,
              {
                ..model,
                update_ux: UpdateCheckFailed(
                  message=notice_text(
                    model.locale,
                    UpdateReply(reason.to_string()),
                  ),
                ),
              },
            )
          } else {
            (@cmd.none, { ..model, update_ux: UpdateUnknown, })
          }
        CheckBroken(version~, reason~) => {
          // A broken package entry can only be the publisher's fault:
          // loud both ways.
          let message = "SeekMoon \{version} is published but its package is unusable: \{reason}"
          let (cmd, next) = if explicit {
            (@cmd.none, model)
          } else {
            model.notify_error(dispatch, message)
          }
          (cmd, { ..next, update_ux: UpdateCheckFailed(message~), })
        }
      }
    }
    UpdateClicked =>
      // The one accent button walks the whole flow: from an offer it retries
      // the download (harmless while conversations run), from a staged
      // download it restarts — asking first when that would cut a
      // conversation off. The button does not render in other states, but a
      // stale click must not restart a download or replay an apply.
      match model.update_ux {
        UpdateAvailable(version~, installable=true) =>
          (
            download_update(dispatch),
            {
              ..model,
              update_ux: DownloadingUpdate(version~, progress={
                downloaded_bytes: 0,
                total_bytes: None,
              }),
            },
          )
        UpdateReady(version~) =>
          if model.any_conversation_busy() {
            (@cmd.none, { ..model, update_ux: ConfirmingRestart(version~), })
          } else {
            (
              apply_update(dispatch),
              { ..model, update_ux: RestartingForUpdate(version~), },
            )
          }
        _ => (@cmd.none, model)
      }
    ConfirmUpdateRestart =>
      if model.update_ux is ConfirmingRestart(version~) {
        (
          apply_update(dispatch),
          { ..model, update_ux: RestartingForUpdate(version~), },
        )
      } else {
        (@cmd.none, model)
      }
    CancelUpdateRestart =>
      if model.update_ux is ConfirmingRestart(version~) {
        // The download already happened; declining the restart just parks
        // the staged release until the user is ready.
        (@cmd.none, { ..model, update_ux: UpdateReady(version~), })
      } else {
        (@cmd.none, model)
      }
    UpdateDownloadProgress(downloaded_bytes~, total_bytes~) =>
      if model.update_ux is DownloadingUpdate(version~, ..) {
        (
          @cmd.none,
          {
            ..model,
            update_ux: DownloadingUpdate(version~, progress={
              downloaded_bytes,
              total_bytes,
            }),
          },
        )
      } else {
        // A late event must not revive a completed, failed, or never-started
        // download after the UI has moved to another state.
        (@cmd.none, model)
      }
    UpdateDownloaded(version~) =>
      if model.update_ux is DownloadingUpdate(..) {
        // Staged, not applied: swapping the bundle under the running app
        // waits for the user's restart, so nothing is pulled out from
        // beneath the process (or the person) mid-flight. The version shown
        // from here on is the one the host actually staged — its deliberate
        // re-check may have picked up a release newer than the one this
        // flow started from.
        (@cmd.none, { ..model, update_ux: UpdateReady(version~), })
      } else {
        (@cmd.none, model)
      }
    UpdateFailed(message~) => {
      // A failed download can be retried. A failed swap means the preflight
      // no longer considers this location replaceable, so withdraw the
      // button until a fresh check says otherwise. Both failures say why.
      let (cmd, next) = model.notify_error(dispatch, message)
      let update_ux = match next.update_ux {
        DownloadingUpdate(version~, ..) =>
          UpdateAvailable(version~, installable=true)
        RestartingForUpdate(version~) =>
          UpdateAvailable(version~, installable=false)
        other => other
      }
      (cmd, { ..next, update_ux, })
    }
    UpdateApplied => (close_window(), model)
    OpenSetup =>
      (
        @cmd.none,
        { ..model, screen: Settings, setup_api_key: "", api_setup_open: false, },
      )
    ReturnToWork =>
      if model.screen.work_screen() is None {
        (
          @cmd.none,
          {
            ..model,
            screen: match model.management_return {
              Some(CodexWork) => Codex
              Some(OpenSeekWork) | None => Chat
            },
          },
        )
      } else {
        (@cmd.none, model)
      }
    DismissApiSetup =>
      (
        @cmd.none,
        { ..model, api_setup_open: false, api_setup_dismissed: true, },
      )
    OpenApiSetup =>
      // Reopening cancels the dismissal — otherwise the next settled
      // snapshot would close the modal the user just asked for.
      (
        @cmd.none,
        { ..model, api_setup_open: true, api_setup_dismissed: false, },
      )
    OpenCodexConfig =>
      (open_codex_config(locale=model.locale, dispatch, model.focused), model)
    CodexConfigOpenFailed(message) => model.notify_error(dispatch, message)
    OpenCodex => {
      let (cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(msg => Codex(channel=model.focused, msg)),
        @codex.Msg::refresh(),
        model.codex,
        model.focused,
        url => open_external_link(dispatch, url),
      )
      (
        cmd,
        {
          ..model,
          screen: Codex,
          sidebar_open: model.sidebar_open && !model.narrow,
          codex,
        },
      )
    }
    CodexDraftRotated(cwd~, id~) => {
      let (cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(msg => Codex(channel=model.focused, msg)),
        @codex.Msg::start_draft(id, cwd),
        model.codex,
        model.focused,
        url => open_external_link(dispatch, url),
      )
      (
        cmd,
        {
          ..model,
          screen: Codex,
          sidebar_open: model.sidebar_open && !model.narrow,
          codex,
        },
      )
    }
    CodexOpenThread(thread_id) => {
      let (cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(msg => Codex(channel=model.focused, msg)),
        @codex.Msg::open_thread(thread_id),
        model.codex,
        model.focused,
        url => open_external_link(dispatch, url),
      )
      (
        cmd,
        {
          ..model,
          screen: Codex,
          sidebar_open: model.sidebar_open && !model.narrow,
          codex,
        },
      )
    }
    CodexArchiveThread(thread_id) => {
      let (cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(msg => Codex(channel=model.focused, msg)),
        @codex.Msg::archive_thread(thread_id),
        model.codex,
        model.focused,
        url => open_external_link(dispatch, url),
      )
      (cmd, { ..model, codex, })
    }
    CodexUnarchiveThread(thread_id) => {
      let (cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(msg => Codex(channel=model.focused, msg)),
        @codex.Msg::unarchive_thread(thread_id),
        model.codex,
        model.focused,
        url => open_external_link(dispatch, url),
      )
      (cmd, { ..model, codex, })
    }
    Codex(channel~, msg) => {
      // A reply, approval request, or status event belongs to the host that
      // produced it. Device focus is the root authority boundary.
      if channel != model.focused {
        return (@cmd.none, model)
      }
      let (cmd, codex) = @codex.update(
        locale=model.locale,
        dispatch.map(next => Codex(channel~, next)),
        msg,
        model.codex,
        channel,
        url => open_external_link(dispatch, url),
      )
      (cmd, { ..model, codex, })
    }
    ToggleSidebar =>
      (@cmd.none, { ..model, sidebar_open: !model.sidebar_open, })
    SidebarModeSelected(sidebar_mode) => (@cmd.none, { ..model, sidebar_mode, })
    // A conversation already on screen has claimed the list; the stored pick
    // only decides what an empty page shows.
    SidebarModeLoaded(sidebar_mode) =>
      if model.sidebar_revealed is None {
        (@cmd.none, { ..model, sidebar_mode, })
      } else {
        (@cmd.none, model)
      }
    WindowFocusChanged(focused) => {
      // Returning to a visible transcript marks its completed turn read.
      // Permission questions remain actionable until answered and therefore
      // continue to contribute to the independently derived badge count.
      let model = { ..model, window_focused: focused, }
      (@cmd.none, model.mark_visible_conversation_read())
    }
    ViewportResized(width~) => {
      let narrow = width <= NarrowBreakpoint
      // The embedded viewer only learns its host's size through layout(),
      // so any resize while a document is up remeasures it — same-side
      // resizes included (a rotation changes the host without crossing the
      // breakpoint).
      let cmds = if model.right_panel_open &&
        @dock.active_file(model.dock) is Some(_) {
        [@fileeditor.request_viewer_remeasure()]
      } else {
        []
      }
      // A horizontal resize can move the right-anchored browser pane
      // without resizing it (`--editor-width` is fixed pixels after a
      // drag): its ResizeObserver stays silent and the geometry signature
      // never changes, so the resize itself must trigger the re-measure.
      if desired_browser_view(model) is Some(_) {
        cmds.push(measure_browser_pane(dispatch))
      }
      let cmd = @cmd.batch(cmds)
      if narrow == model.narrow {
        (cmd, model)
      } else {
        // Crossing the breakpoint resets the sidebar to the new layout's
        // default: an open column on wide, a closed drawer on narrow.
        (cmd, { ..model, narrow, sidebar_open: !narrow, })
      }
    }
    SaveApiKey => {
      guard model.host_settings_loaded() else { return (@cmd.none, model) }
      let api_key = model.setup_api_key.trim().to_owned()
      if api_key.is_empty() {
        (@cmd.none, model)
      } else {
        match model.api_provider {
          // The key goes straight to the host's store; the mirror keeps
          // only its presence. The save never navigates — it lands on
          // whatever page the form (Settings or the modal over any screen)
          // was open over. A save that completes the setup retires the
          // modal optimistically; one that leaves it incomplete (Custom
          // with no URL yet) keeps the modal up mid-setup. A failed save
          // comes back as a toast.
          Deepseek | Glm | OpenRouter | Custom as provider => {
            let next = {
              ..model,
              deepseek_key_saved: model.deepseek_key_saved ||
              provider is Deepseek,
              glm_key_saved: model.glm_key_saved || provider is Glm,
              custom_key_saved: model.custom_key_saved ||
              provider is (OpenRouter | Custom),
              setup_api_key: "",
              settings_saves: model.settings_saves + 1,
            }
            (
              push_host_settings(
                dispatch,
                model.focused,
                api_key_settings_patch(provider, api_key),
                model.focused_connection_generation(),
              ),
              next.settle_api_setup(),
            )
          }
        }
      }
    }
    OpenSchedules => open_schedules(dispatch, model)
    SchedulePage(msg) => update_schedules(dispatch, msg, model)
    OpenSkills => {
      // The page decides whether its catalog still needs fetching; the
      // installed list is the root's mirror, cheap, and refreshed on every
      // open.
      let (page_cmd, skills) = model.skills.opening(
        dispatch.map(msg => Skills(msg)),
        model.skills_input(),
      )
      (
        @cmd.batch([page_cmd, fetch_installed_skills(dispatch, model.focused)]),
        { ..model, screen: Skills, skills, },
      )
    }
    Skills(msg) => {
      let (page_cmd, skills, outcome) = model.skills.handle(
        dispatch.map(next => Skills(next)),
        msg,
        model.skills_input(),
      )
      let model = { ..model, skills, }
      // A settled install or uninstall changed the library the root owns;
      // what the page shows must come from disk, not from a client-side
      // guess.
      guard outcome is Some(@skills.LibraryChanged(channel~)) else {
        return (page_cmd, model)
      }
      (@cmd.batch([page_cmd, fetch_installed_skills(dispatch, channel)]), model)
    }
    Send | SendFollowup(_) | SendInBackground => {
      // Re-pinning is for the reader of this conversation's transcript.
      let scroll = if msg is SendInBackground {
        @cmd.none
      } else {
        @transcript_component.scroll_to_latest()
      }
      let followup = match msg {
        SendFollowup(choice) => Some(choice)
        _ => None
      }
      let followup_behavior = match msg {
        SendFollowup(@composer.SteerNow) => FollowupSteer
        SendFollowup(@composer.QueueNext) => FollowupQueue
        _ => model.followup_behavior
      }
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.is_archived_read_only() || model.scheduled_session_read_only(conv) {
        return (@cmd.none, model)
      }
      // A large selection is not allowed to degrade to a prompt marker while
      // its immutable JSONL snapshot is still being written.
      if conv.pending_semantic_submission is Some(_) {
        return (@cmd.none, model)
      }
      let checkout = model.conversation_placement(conv)
      // The outgoing prompt is the typed text with the chips folded in as the
      // `<user_mentions>` envelope. The envelope is itself valid prompt
      // content, so an explicitly attached chip can be sent without text.
      let task = @composer.Draft::{
          images: conv.images,
          task: conv.task,
          mentions: conv.mentions,
        }
        .prompt()
        .trim()
        .to_owned()
      let sendable = conv.draft_sendable() &&
        model.bridge_state() is Connected &&
        model.api_ready() &&
        checkout is Some(placement) &&
        !(placement is @interop.MissingWorktree(..))
      let large_reference = conv.mentions
        .iter()
        .filter_map(mention => {
          if mention.ref_ is @mention_context.SemanticSearch(reference) &&
            !reference.is_inlineable() {
            Some(reference)
          } else {
            None
          }
        })
        .nth(0)
      if sendable && large_reference is Some(reference) {
        let (model, submission_id) = model.allocate_submission_id()
        // The composer freezes on `pending_semantic_submission` so repeated
        // clicks are ignored while the Host writes the immutable snapshot.
        let pending_semantic_submission : PendingSemanticSubmission = {
          submission_id,
          reference,
          task: conv.task,
          mentions: conv.mentions.copy(),
          followup,
        }
        return (
          pending_semantic_submission.materialize(dispatch, {
            channel: conv.device,
            session: conv.session_id,
          }),
          model.replace_conversation({
            ..conv,
            pending_semantic_submission: Some(pending_semantic_submission),
          }),
        )
      }
      if !sendable {
        (@cmd.none, model)
      } else if conv.is_running() {
        // Submitting while this conversation's turn runs steers it: the text
        // is folded into the running turn at its next step boundary and
        // echoed back as a `steer_applied` event. A turn being cancelled
        // cannot be steered — the steer could outlive the dying turn in the
        // engine's queue and contaminate a later prompt — so the text stays
        // in the composer.
        if conv.run is Open(run_id~, stage~) && !(stage is Cancelling) {
          if conv.queue_edit_id is Some(id) {
            return (
              queue_openseek(
                locale=model.locale,
                dispatch,
                model.focused,
                conv.session_id,
                @protocol.QueueEdit(
                  id~,
                  text=task,
                  images=conv.images.map(image => image.url),
                ),
                run_id,
              ),
              // Keep the edit in the composer until the in-memory mutation is
              // accepted. A refusal then loses no user-authored text.
              model,
            )
          }
          let (model, submission_id) = model.allocate_submission_id()
          let conv = conv.enqueue_steer(
            submission_id,
            Some(run_id),
            task,
            conv.task,
            conv.mentions,
            followup_behavior,
            images=conv.images,
          )
          let command = if followup_behavior is FollowupQueue {
            queue_openseek(
              locale=model.locale,
              dispatch,
              model.focused,
              conv.session_id,
              @protocol.QueueAdd(
                id=submission_id,
                text=task,
                images=conv.images.map(image => image.url),
              ),
              run_id,
            )
          } else {
            steer_openseek(
              dispatch,
              model.focused,
              conv.session_id,
              submission_id,
              task,
              run_id,
              images=conv.images.map(image => image.url),
            )
          }
          (
            @cmd.batch([command, scroll]),
            {
              ..model.replace_conversation({
                ..conv,
                task: "",
                images: [],
                mentions: [],
                composer_draft_present: false,
              }),
            },
          )
        } else {
          (@cmd.none, model)
        }
      } else if !(conv.compaction is NotCompacting) {
        // A prompt submitted mid-compaction would sit in the serve engine's
        // queue behind it, where Stop (which cancels only the compaction)
        // cannot reach it — the user's cancel would not stop the submitted
        // work. A queued or just-requested compaction is the same gap one
        // step earlier: the command is on its way and compaction_started has
        // not yet arrived. The draft stays in the composer until the
        // compaction settles.
        (@cmd.none, model)
      } else {
        let (model, submission_id) = model.allocate_submission_id()
        // The worktree launch mode acts until a create has bound the
        // conversation; the eligibility must survive a rejected setup
        // attempt (see `wants_fresh_worktree`). Read before the pending
        // prompt below mutates the conversation.
        let fresh_worktree = conv.wants_fresh_worktree()
        let conv = {
          ..conv,
          pending_prompt: Some({
            submission_id,
            draft: conv.task,
            mentions: conv.mentions.copy(),
            images: conv.images,
          }),
        }
        let next = {
          ..conv,
          task: "",
          images: [],
          mentions: [],
          composer_draft_present: false,
          run: Starting(submission_id~),
          // A turn starts from nothing observed. That includes the terminal
          // floor: the store may have advanced through an external CLI while
          // this page was idle, so only the real Started seam's causal
          // snapshot may establish this run's predecessor terminal.
          turn: RunState::for_run(conv.durable_frontier()),
          // The submit is the moment this run began as far as the user is
          // concerned: the wait they are watching starts here, not at the
          // host's `started`.
          run_started_ms: Some(@interop.now_ms()),
        }
        // The worktree launch mode's first submit creates the environment
        // (the host names it, binds this conversation) and starts inside
        // it, as one command; every other submit is a plain start — a
        // bound session's cwd comes from the host's registry.
        let start_cmd = if fresh_worktree &&
          conv.workspace is Project(root=workspace) {
          start_in_new_worktree(
            locale=model.locale,
            dispatch,
            model.focused,
            task,
            submission_id,
            conv.engine_model,
            model.reasoning_for(conv.engine_model),
            model.max_steps,
            conv.session_id,
            workspace,
            images=conv.images.map(image => image.url),
          )
        } else {
          start_openseek(
            dispatch,
            model.focused,
            task,
            submission_id,
            conv.engine_model,
            model.reasoning_for(conv.engine_model),
            model.max_steps,
            conv.session_id,
            workspace=conv.project(),
            images=conv.images.map(image => image.url),
          )
        }
        // Re-pin now, before the durable User item arrives, so the early
        // streamed work is visible even if the reader had scrolled up.
        (@cmd.batch([start_cmd, scroll]), model.replace_conversation(next))
      }
    }
    Stop => {
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.run is Open(run_id~, ..) {
        (
          cancel_openseek(locale=model.locale, dispatch, model.focused, run_id),
          model.replace_conversation({
            ..conv,
            run: Open(run_id~, stage=Cancelling),
          }),
        )
      } else {
        (@cmd.none, model)
      }
    }
    // Answering is refused once already answered, so a double click cannot
    // send two decisions for one question. The card is marked rather than
    // removed: it comes off screen when the engine says the question settled,
    // which is the only evidence the answer arrived.
    ApprovalAnswered(allow~) => {
      guard model.active_conversation() is Some(conv) &&
        conv.pending_approval is Some(pending) &&
        !pending.answered else {
        return (@cmd.none, model)
      }
      (
        approve_openseek(
          locale=model.locale,
          dispatch,
          model.focused,
          conv.session_id,
          pending.id,
          pending.run_id,
          allow~,
        ),
        model.replace_conversation({
          ..conv,
          pending_approval: Some({ ..pending, answered: true, }),
        }),
      )
    }
    ApprovalAnswerFailed(channel~, session~, id~) => {
      guard model.find_conversation(channel, session) is Some(conv) &&
        conv.pending_approval is Some(pending) &&
        pending.id == id else {
        return (@cmd.none, model)
      }
      (
        @cmd.none,
        model.replace_conversation({
          ..conv,
          pending_approval: Some({ ..pending, answered: false, }),
        }),
      )
    }
    NewChat =>
      // A fresh conversation can start at any time: the current one keeps
      // running in the background and stays one sidebar click away. It lands
      // in the active workspace — the one the on-screen conversation uses —
      // and starts with whichever agent the model chip was last picked from.
      if model.focused_device() is Some(dev) &&
        dev.active_project is Some(project) &&
        dev.is_chat_workspace(project) {
        update(dispatch, CreateChat(model.focused), model)
      } else if model.default_agent is CodexAgent {
        new_codex_chat(
          dispatch,
          model,
          model.focused_device().bind(dev => dev.active_project),
        )
      } else {
        (
          rotate_session(dispatch, model.focused),
          { ..model, loading_conversation: None, },
        )
      }
    NewChatIn(channel, workspace) => {
      // A workspace section's own "new chat": the fresh conversation lands in
      // that project, and the workspace stays active for the next one. The
      // sidebar components reveal the active row themselves, so no disclosure
      // state needs unfolding here. The explicit channel lets this handler
      // move device selection before creating the chat.
      guard model.device_state(channel) is Some(_) else {
        return (@cmd.none, model)
      }
      let (focus_cmd, model) = focus_channel(dispatch, model, channel)
      let model = {
        ..model.with_active_project(workspace),
        chat_creation: None,
        loading_conversation: None,
      }
      let (start_cmd, model) = if model.default_agent is CodexAgent {
        new_codex_chat(dispatch, model, workspace)
      } else {
        (rotate_session(dispatch, channel), model)
      }
      (@cmd.batch([focus_cmd, start_cmd]), model)
    }
    ToggleWorktreeMode => {
      // One predicate with the chip that offers this — see
      // `can_choose_launch_mode`. Two spellings of "may still choose" is how
      // the toggle stayed live through a placement chain the chip had
      // already committed to.
      //
      // The chip decides only THIS conversation. The workspace's default for
      // future chats is its own durable setting, edited on the workspace
      // settings page — a per-chat exception must not silently rewrite it.
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if model.can_choose_launch_mode(conv) && conv.workspace is Project(..) {
        (
          @cmd.none,
          model.replace_conversation({
            ..conv,
            worktree_mode: !conv.worktree_mode,
          }),
        )
      } else {
        (@cmd.none, model)
      }
    }
    RetryWorktreePlacement => {
      guard model.active_conversation() is Some(conv) &&
        model.conversation_placement(conv) is None &&
        model.device_state(conv.device) is Some(dev) else {
        return (@cmd.none, model)
      }
      let workspace = conv.project()
      let request_generation = dev.worktrees_request_generation + 1
      (
        fetch_worktrees(
          dispatch,
          conv.device,
          workspace,
          dev.connection_generation,
          request_generation,
        ),
        model.replace_device({
          ..dev,
          worktrees_request_generation: request_generation,
        }),
      )
    }
    RepairWorktree => {
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      guard model.conversation_placement(conv)
        is Some(@interop.MissingWorktree(..)) &&
        conv.workspace is Worktree(project=workspace, ..) else {
        return (@cmd.none, model)
      }
      (
        repair_worktree_cmd(
          locale=model.locale,
          dispatch,
          conv.device,
          workspace.path,
          conv.session_id,
        ),
        model,
      )
    }
    ConfirmArchiveDiscard =>
      match model.archive_confirm {
        Some(confirm) => {
          // The dialog's confirm IS the force: retry the archive discarding
          // the worktree's uncommitted changes. Same generation dance as
          // the plain archive click.
          guard model.device_state(confirm.channel) is Some(dev) else {
            return (@cmd.none, { ..model, archive_confirm: None, })
          }
          let sessions_request_generation = dev.sessions_request_generation + 1
          let archived_request_generation = dev.archived_request_generation + 1
          (
            archive_session(
              dispatch,
              confirm.channel,
              confirm.session,
              dev.connection_generation,
              sessions_request_generation,
              archived_request_generation,
              force=true,
            ),
            {
              ..model.replace_device({
                ..dev,
                sessions_request_generation,
                archived_request_generation,
              }),
              archive_confirm: None,
            },
          )
        }
        None => (@cmd.none, model)
      }
    CancelArchiveDiscard => (@cmd.none, { ..model, archive_confirm: None, })
    ConfirmDeleteArchivedSession =>
      match model.archived_delete_confirm {
        Some(confirm) => {
          guard model.device_state(confirm.channel) is Some(dev) else {
            return (@cmd.none, { ..model, archived_delete_confirm: None, })
          }
          let archived_request_generation = dev.archived_request_generation + 1
          (
            delete_archived_session(
              dispatch,
              confirm.channel,
              confirm.key,
              confirm.sessions,
              dev.connection_generation,
              archived_request_generation,
            ),
            {
              ..model.replace_device({ ..dev, archived_request_generation, }),
              archived_delete_confirm: None,
            },
          )
        }
        None => (@cmd.none, model)
      }
    CancelDeleteArchivedSession =>
      (@cmd.none, { ..model, archived_delete_confirm: None, })
    SessionRotated(owner) => {
      // A delayed rotation is owned by the channel that requested it. A focus
      // switch overtakes it; activating the old owner's id here would yank the
      // user back to the host they already left.
      // A chat happens in a project. A rotation that arrives with none to
      // land in — every project was detached while it was in flight — has
      // nowhere to put the fresh session, and the view stays on onboarding.
      guard owner.channel == model.focused &&
        model.device_state(owner.channel) is Some(dev) &&
        dev.target_project() is Some(project) else {
        return (@cmd.none, model)
      }
      let existing = model.find_conversation(owner.channel, owner.session)
      let activated = model.activate(owner.channel, owner.session, project)
      // A rotation creates the conversation, so stamp it with the workspace
      // it was asked into and that workspace's saved default. An existing
      // conversation keeps its own choice if the reply is replayed.
      let conversations = activated.conversations.map(conv => {
        if conv.device == owner.channel &&
          conv.session_id == owner.session &&
          conv.messages.length() == 0 &&
          !conv.is_running() {
          {
            ..conv,
            workspace: Project(root=project),
            worktree_mode: if existing is Some(existing) {
              existing.worktree_mode
            } else {
              dev.default_worktree_mode(project)
            },
          }
        } else {
          conv
        }
      })
      (
        @cmd.none,
        {
          ..activated,
          conversations,
          screen: Chat,
          loading_conversation: None,
        },
      )
    }
    CreateChat(channel) => {
      guard !model.chat_creation_pending() &&
        model.pending_project_adoption is None else {
        return (@cmd.none, model)
      }
      guard model.device_state(channel) is Some(dev) && dev.bridge is Connected else {
        return (@cmd.none, model)
      }
      let generation = model.chat_creation_sequence + 1
      let (focus_cmd, model) = focus_channel(dispatch, model, channel)
      (
        @cmd.batch([
          focus_cmd,
          create_chat_workspace(dispatch, channel, generation~),
        ]),
        {
          ..model,
          project_picker: None,
          chat_creation: Some((channel, generation, dev.connection_generation)),
          chat_creation_sequence: generation,
        },
      )
    }
    ChatWorkspaceCreated(channel~, generation~, result~) => {
      guard model.chat_creation is Some((owner, expected, connection)) &&
        owner == channel &&
        expected == generation else {
        return (@cmd.none, model)
      }
      let model = { ..model, chat_creation: None, }
      guard model.device_state(channel) is Some(dev) &&
        dev.connection_generation == connection else {
        return (@cmd.none, model)
      }
      match result {
        Ok(path) => adopt_picked_directory(dispatch, channel, path, model)
        Err(message) =>
          model.notify_error(
            dispatch,
            notice_text(model.locale, CreateChat(message.to_string())),
          )
      }
    }
    PickProject(channel) => {
      // Focus moves for the surrounding UI, while the picker itself keeps
      // `channel` as its owner through every later navigation and confirm.
      guard model.device_state(channel) is Some(_) else {
        return (@cmd.none, model)
      }
      let (focus_cmd, model) = focus_channel(dispatch, model, channel)
      // Retire Quick Open first. The picker's capture-phase keys claim Enter
      // and Escape for the browse session, so a palette left standing would
      // paint over the picker while every keystroke went to the picker behind
      // it. The palette holds nothing worth preserving — unlike the picker's
      // own browse position, which is why it refuses to reopen over itself.
      let (quick_open_cmd, quick_open) = model.quick_open.close()
      let (browse_cmd, picker) = @project_picker.State::open(
        channel,
        dispatch.map(msg => ProjectPicker(msg)),
      )
      (
        @cmd.batch([focus_cmd, quick_open_cmd, browse_cmd]),
        {
          ..model,
          // A newer project choice supersedes any outstanding chat allocation.
          // Its directory may still be created, but its reply must not adopt it.
          chat_creation: None,
          quick_open,
          project_picker: Some(picker),
        },
      )
    }
    AddProjectRequested =>
      // The chord acts on the focused device, like the sidebar section's ＋.
      // While the picker is already open it does nothing: restarting the
      // browse would yank the listing back to home mid-navigation.
      if model.project_picker is Some(_) {
        (@cmd.none, model)
      } else {
        update(dispatch, PickProject(model.focused), model)
      }
    ProjectPicker(msg) =>
      match model.project_picker {
        Some(picker) => {
          let (cmd, next, outcome) = @project_picker.State::handle(
            locale=model.locale,
            picker,
            dispatch.map(msg => ProjectPicker(msg)),
            msg,
          )
          let model = { ..model, project_picker: next, }
          match outcome {
            None => (cmd, model)
            // A failed browse or create leaves the previous listing usable.
            Some(@project_picker.Outcome::Failed(message)) => {
              let (toast, model) = model.notify_error(dispatch, message)
              (@cmd.batch([cmd, toast]), model)
            }
            // Confirm registers the directory the host last listed — always
            // something it confirmed exists — never raw pasted text; a paste
            // navigates (and validates) first. The pending adoption later
            // focuses the project the add committed.
            Some(@project_picker.Outcome::Picked(channel, path)) => {
              let (add_cmd, next) = adopt_picked_directory(
                dispatch, channel, path, model,
              )
              (@cmd.batch([cmd, add_cmd]), next)
            }
          }
        }
        None => (@cmd.none, model)
      }
    RemoveProject(channel, path) =>
      // The row itself leaves with the registry commit broadcast; its open
      // "…" menu is component state and leaves with the keyed row.
      if @resource.belongs_to(path, channel) {
        (remove_project(dispatch, channel, path.path), model)
      } else {
        (@cmd.none, model)
      }
    OpenWorkspaceSettings(channel, workspace) =>
      (
        @cmd.none,
        {
          ..model,
          workspace_settings_dialog: Some({
            target: { channel, workspace, },
            pending_save: None,
            error: None,
          }),
        },
      )
    CloseWorkspaceSettings =>
      (@cmd.none, { ..model, workspace_settings_dialog: None, })
    WorkspaceDefaultModeChosen(channel, workspace, value) => {
      guard model.device_state(channel) is Some(dev) else {
        return (@cmd.none, model)
      }
      let worktree_mode = value == "worktree"
      // Apply optimistically under a fresh token, so a slower list reply
      // cannot roll the dialog's select back; the commit broadcast lands on a
      // newer token still. The failure path re-reads the disk state.
      let request_generation = dev.workspace_settings_request_generation + 1
      (
        save_workspace_settings(
          dispatch,
          channel,
          workspace,
          connection_generation=dev.connection_generation,
          request_generation~,
          worktree_mode~,
        ),
        model
        .begin_workspace_settings_save(channel, workspace, request_generation)
        .replace_device({
          ..dev.with_workspace_settings(
            workspace,
            worktree_mode,
            generation=request_generation,
          ),
          workspace_settings_request_generation: request_generation,
        }),
      )
    }
    WorkspaceSubmodulesChosen(channel, workspace, value) => {
      guard model.device_state(channel) is Some(dev) &&
        dev.workspace_settings_row(workspace) is Some(row) else {
        return (@cmd.none, model)
      }
      let checkout_submodules = match value {
        "checkout" => true
        "skip" => false
        _ => return (@cmd.none, model)
      }
      // Preserve the workspace's launch mode locally and patch only the
      // submodule field on disk. The generation fence has the same job as
      // the launch-mode edit above: an older read cannot undo this choice.
      let request_generation = dev.workspace_settings_request_generation + 1
      (
        save_workspace_settings(
          dispatch,
          channel,
          workspace,
          connection_generation=dev.connection_generation,
          request_generation~,
          checkout_submodules~,
        ),
        model
        .begin_workspace_settings_save(channel, workspace, request_generation)
        .replace_device({
          ..dev.with_workspace_settings(
            workspace,
            row.worktree_mode,
            generation=request_generation,
            checkout_submodules~,
          ),
          workspace_settings_request_generation: request_generation,
        }),
      )
    }
    WorkspaceSubmoduleTimeoutChosen(channel, workspace, value) => {
      guard model.device_state(channel) is Some(dev) &&
        dev.workspace_settings_row(workspace) is Some(row) else {
        return (@cmd.none, model)
      }
      let submodule_checkout_timeout_seconds = match value {
        "5" => 5
        "10" => 10
        "30" => 30
        "60" => 60
        _ => return (@cmd.none, model)
      }
      // Patch only the timeout and keep both neighboring workspace choices.
      // A fresh generation prevents an older read from undoing this select.
      let request_generation = dev.workspace_settings_request_generation + 1
      (
        save_workspace_settings(
          dispatch,
          channel,
          workspace,
          connection_generation=dev.connection_generation,
          request_generation~,
          submodule_checkout_timeout_seconds~,
        ),
        model
        .begin_workspace_settings_save(channel, workspace, request_generation)
        .replace_device({
          ..dev.with_workspace_settings(
            workspace,
            row.worktree_mode,
            generation=request_generation,
            checkout_submodules=row.checkout_submodules,
            submodule_checkout_timeout_seconds~,
          ),
          workspace_settings_request_generation: request_generation,
        }),
      )
    }
    ArchiveSession(channel, session_id) => {
      // Archiving acts on the row's own device and never moves focus.
      guard model.device_state(channel) is Some(dev) else {
        return (@cmd.none, model)
      }
      let sessions_request_generation = dev.sessions_request_generation + 1
      let archived_request_generation = dev.archived_request_generation + 1
      (
        archive_session(
          dispatch,
          channel,
          session_id,
          dev.connection_generation,
          sessions_request_generation,
          archived_request_generation,
        ),
        model.replace_device({
          ..dev,
          sessions_request_generation,
          archived_request_generation,
        }),
      )
    }
    UnarchiveSession(channel, session_id) => {
      guard model.device_state(channel) is Some(dev) else {
        return (@cmd.none, model)
      }
      let sessions_request_generation = dev.sessions_request_generation + 1
      let archived_request_generation = dev.archived_request_generation + 1
      (
        unarchive_session(
          dispatch,
          channel,
          session_id,
          dev.connection_generation,
          sessions_request_generation,
          archived_request_generation,
        ),
        model.replace_device({
          ..dev,
          sessions_request_generation,
          archived_request_generation,
        }),
      )
    }
    DeleteArchivedSession(channel, key) => {
      // Only a currently visible archived row may open the destructive dialog;
      // stale clicks cannot authorize deletion of an identity no longer shown.
      guard model.device_state(channel) is Some(dev) &&
        key.workspace_payload(channel) is Some(_) &&
        dev.archived.iter().find_first(item => key.matches(item))
        is Some(record) else {
        return (@cmd.none, model)
      }
      let sessions : Array[String] = [key.session]
      for row in @transcript.session_tree(dev.archived) {
        if key.matches(row.item) {
          for child in row.children {
            sessions.push(child.id)
          }
        }
      }
      (
        @cmd.none,
        {
          ..model,
          archived_delete_confirm: Some({
            channel,
            key,
            sessions,
            title: session_item_label(record),
          }),
        },
      )
    }
    ConversationRenameRequested(id~, label~) =>
      // One edit at a time: a save still in flight keeps its field, so its
      // failure has somewhere to be shown.
      if id.source() is (@conversation.OpenSeekLive | @conversation.CodexLive) &&
        !(model.conversation_rename is Some({ saving: true, .. })) {
        (
          focus_conversation_rename(),
          {
            ..model,
            conversation_rename: Some({
              id,
              original: label,
              draft: label,
              saving: false,
              focus_left: false,
            }),
          },
        )
      } else {
        (@cmd.none, model)
      }
    ConversationRenameEdited(id~, edit~) =>
      match model.conversation_rename {
        Some(rename) if rename.id == id =>
          model.edit_conversation_rename(dispatch, rename, edit)
        _ => (@cmd.none, model)
      }
    ConversationRenameSucceeded(id) =>
      match model.conversation_rename {
        Some(rename) if rename.id == id =>
          model.finish_conversation_rename(rename)
        _ => (@cmd.none, model)
      }
    ConversationRenameFailed(id~, message~) =>
      match model.conversation_rename {
        Some(rename) if rename.id == id => {
          // The title is unchanged, and the row may be folded away by now:
          // the reason goes to the toast rail, which is always on screen.
          let (focus, model) = model.finish_conversation_rename(rename)
          let (toast, model) = model.notify_error(
            dispatch,
            (match model.locale {
              SimplifiedChinese => "重命名失败："
              TraditionalChinese => "重新命名失敗："
              Japanese => "名前を変更できませんでした："
              English => "Rename failed: "
              Spanish => "No se pudo cambiar el nombre: "
            }) +
            message,
          )
          (@cmd.batch([focus, toast]), model)
        }
        _ => (@cmd.none, model)
      }
    NotificationClicked(run_id~) => {
      // Proton notifications are emitted only for the embedded local host. A
      // finished run usually matches by last run id; a permission request
      // still owns the active run while its tool waits for the answer.
      let conv = if model.conversation_by_last_run(Local, run_id) is Some(conv) {
        Some(conv)
      } else {
        model.conversation_by_run(Local, run_id)
      }
      if conv is Some(conv) {
        update_msg(dispatch, OpenSession(conv.device, conv.session_id), model)
      } else {
        (@cmd.none, model)
      }
    }
    // A transcript link naming a session on the device already focused. It
    // delegates rather than duplicating: the sub-run child this opens is an
    // ordinary durable session, and `OpenSession` is how one is opened.
    OpenSessionHere(session_id) =>
      update_msg(dispatch, OpenSession(model.focused, session_id), model)
    OpenSession(channel, session_id) =>
      // Selecting a conversation always returns to the chat — including
      // re-selecting the active one from the Skills page. The explicit channel
      // may also move device selection before the focused-scoped mirrors
      // refetch and the conversation opens there; current sidebar rows pass
      // the selected channel.
      if session_id.is_empty() {
        (@cmd.none, model)
      } else {
        // A row click that raced its device's removal has nowhere to go.
        guard model.device_state(channel) is Some(_) else {
          return (@cmd.none, model)
        }
        let (focus_cmd, model) = focus_channel(dispatch, model, channel)
        guard model.live_selection(channel, session_id) is Some(target) else {
          return (@cmd.none, model)
        }
        let model = {
          ..model,
          selected_conversation: Some(target),
          conversation_load_failure: None,
          screen: Chat,
        }
        let (cmd, model) = open_session_on(dispatch, channel, model, session_id)
        (@cmd.batch([focus_cmd, cmd]), model)
      }
    RetrySelectedConversation =>
      match model.selected_conversation {
        Some(selection) if selection.record is LiveRecord =>
          update_msg(
            dispatch,
            OpenSession(selection.channel, selection.session),
            { ..model, conversation_load_failure: None, },
          )
        Some(selection) if selection.record is ArchivedRecord =>
          update_msg(
            dispatch,
            OpenArchivedSession(
              selection.channel,
              session=selection.session,
              workspace=selection.workspace,
            ),
            { ..model, conversation_load_failure: None, },
          )
        _ => (@cmd.none, model)
      }
    OpenArchivedSession(channel, session~, workspace~) => {
      guard !session.is_empty() && model.device_state(channel) is Some(dev) else {
        return (@cmd.none, model)
      }
      // The row may have been restored while its click was queued. Re-read
      // the current archived index and use its placement rather than opening
      // a stale archived target or trusting an obsolete workspace hint.
      let key : ArchiveRecordKey = { session, workspace, }
      guard dev.archived.any(item => key.matches(item)) &&
        !(dev.archive_override(key) is Some(ArchiveLive)) else {
        return (@cmd.none, model)
      }
      let (focus_cmd, model) = focus_channel(dispatch, model, channel)
      let model = {
        ..model,
        selected_conversation: Some({
          channel,
          session,
          workspace,
          record: ArchivedRecord,
        }),
        conversation_load_failure: None,
        screen: Chat,
      }
      let (cmd, model) = model.open_archived_session_on(
        dispatch, channel, session, workspace,
      )
      (@cmd.batch([focus_cmd, cmd]), model)
    }
    ColorSchemeChanged(dark) => {
      let model = { ..model, system_dark: dark, }
      match model.theme {
        System =>
          (
            @cmd.batch([
              System.apply(dark, model.is_desktop, dispatch),
              browser_set_theme_for_pages(dispatch, model, dark),
            ]),
            model,
          )
        Light | Dark => (@cmd.none, model)
      }
    }
    MinimalTranscriptChanged(enabled) =>
      (
        save_minimal_transcript(enabled),
        { ..model, minimal_transcript: enabled, },
      )
    FpsOverlayChanged(enabled) =>
      (save_fps_overlay(enabled), { ..model, fps_overlay_enabled: enabled, })
    ThemeChanged(value) => {
      let theme = Theme::parse(value, model.theme)
      let model = { ..model, select_menu: None, }
      if theme == model.theme {
        (@cmd.none, model)
      } else {
        (
          @cmd.batch([
            theme.apply(model.system_dark, model.is_desktop, dispatch),
            browser_set_theme_for_pages(
              dispatch,
              model,
              theme.is_dark(model.system_dark),
            ),
            theme.save(),
          ]),
          { ..model, theme, },
        )
      }
    }
    FontSizeAdjusted(delta) => {
      let size = (model.app_font_size.base_pixels() + delta).clamp(
        min=AppFontSizeMinPixels,
        max=AppFontSizeMaxPixels,
      )
      update(dispatch, FontSizeChanged(size.to_string()), model)
    }
    FontSizeChanged(value) => {
      let app_font_size = AppFontSize::parse(value, model.app_font_size)
      let model = { ..model, select_menu: None, }
      if app_font_size == model.app_font_size {
        (@cmd.none, model)
      } else {
        (
          @cmd.batch([app_font_size.apply(), app_font_size.save()]),
          { ..model, app_font_size, },
        )
      }
    }
    OpenFile(path) => request_open_path(dispatch, model, path, None)
    RevealFile(path) => {
      guard model.is_desktop &&
        model.active_checkout() is Some(active) &&
        active.owner.channel is Local &&
        active.placement is Some(placement) &&
        placement.checkout_root() is Some(cwd) else {
        return (@cmd.none, model)
      }
      (
        reveal_file(
          dispatch,
          active.owner.channel,
          active.owner.session,
          cwd,
          path,
        ),
        model,
      )
    }
    OpenPathResolved(context, reply) =>
      finish_open_path(dispatch, model, context, reply)
    ToggleGitDetails => {
      let opening = !model.git_details_open
      let model = { ..model, git_details_open: opening, }
      guard opening else { return (@cmd.none, model) }
      // Opening it is a request for current information, and everything it
      // shows goes stale on its own: CI finishes minutes after the run that
      // started it, and the working tree keeps moving. Nothing else looks
      // again until the next run, so without this the chip's tint can sit on
      // "running" long after the checks settled.
      //
      // The branch probe is the refresh — it re-counts the lines and, through
      // its reply, re-runs the pull-request lookup, which is the same path
      // every run boundary takes, in-flight fencing and all.
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      probe_branch(
        dispatch,
        model,
        conv.device,
        conv.session_id,
        model.conversation_root(conv),
      )
    }
    CloseGitDetails => (@cmd.none, { ..model, git_details_open: false, })
    TranscriptLeft(slot~, scroll~) =>
      (
        @cmd.none,
        {
          ..model,
          transcript_scroll: model.transcript_scroll.add(slot, scroll),
        },
      )
    ToggleRightPanel => {
      let opening = !model.right_panel_open
      // A direct visibility toggle has no later semantic action to fence old
      // editor replies. Actions such as OpenFile and JumpToLocation spend
      // their own navigation generation before opening the panel.
      let model = if !opening || model.dock.active is Some(_) {
        model.begin_editor_navigation()
      } else {
        model
      }
      let model = {
        ..model,
        right_panel_open: opening,
        right_panel_menu_open: false,
        right_panel_expanded: if opening {
          model.right_panel_expanded
        } else {
          false
        },
      }
      (@cmd.none, model)
    }
    ToggleRightPanelMenu =>
      (
        @cmd.none,
        { ..model, right_panel_menu_open: !model.right_panel_menu_open, },
      )
    ToggleRightPanelExpanded => {
      guard model.right_panel_open else { return (@cmd.none, model) }
      let model = {
        ..model,
        right_panel_menu_open: false,
        right_panel_expanded: !model.right_panel_expanded,
        sidebar_open: model.right_panel_expanded && model.sidebar_open,
      }
      let cmd = if @dock.active_file(model.dock) is Some(_) {
        @fileeditor.request_viewer_remeasure()
      } else {
        @cmd.none
      }
      (cmd, model)
    }
    CloseRightPanelMenu =>
      (@cmd.none, { ..model, right_panel_menu_open: false, })
    DockTabMenuChanged(open) =>
      (
        @cmd.none,
        {
          ..model,
          dock_tab_menu_open: open,
          right_panel_menu_open: if open {
            false
          } else {
            model.right_panel_menu_open
          },
        },
      )
    CloseDockTabs(selection) => close_dock_tabs(dispatch, model, selection)
    OpenGoalEditor => {
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.is_archived_read_only() {
        return (@cmd.none, model)
      }
      // Opening goal mode touches only this conversation, so an unsaved edit
      // waiting on another one is untouched — the reason the draft lives here
      // rather than in a single model-wide slot.
      //
      // A menu left open over the prompt does not survive the switch: it was
      // computed from the prompt draft, and a goal draft has no slash
      // commands to offer. Accepting one of its stale rows would replace the
      // goal being written, or run something else entirely.
      (
        @cmd.none,
        {
          ..model.replace_conversation({
            ..conv,
            goal_edit: Some({ draft: conv.goal_draft_seed(), }),
          }),
        },
      )
    }
    GoalDraftEdited(draft) => {
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.is_archived_read_only() {
        return (@cmd.none, model)
      }
      if conv.goal_edit is Some(_) {
        (
          @cmd.none,
          model.replace_conversation({ ..conv, goal_edit: Some({ draft, }), }),
        )
      } else {
        (@cmd.none, model)
      }
    }
    SubmitGoal => {
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.is_archived_read_only() || model.scheduled_session_read_only(conv) {
        return (@cmd.none, model)
      }
      guard conv.goal_edit is Some(edit) else { return (@cmd.none, model) }
      let text = edit.draft.trim().to_owned()
      // A blank draft has nothing to set (the button is disabled; this also
      // catches Enter); goal mode stays open for the user to finish.
      guard !text.is_empty() else { return (@cmd.none, model) }
      // Goal mode closes, but the text stays as `goal_pending` until the
      // durable marker lands. `agent.goal` returning only means the command
      // reached the engine's stdin — the append behind it can still fail, and
      // then nothing would carry the user's writing.
      let (model, command) = model.allocate_submission_id()
      (
        send_goal(dispatch, model, conv, command, Some(text)),
        model.replace_conversation({
          ..conv,
          goal_edit: None,
          goal_pending: Some({
            id: command,
            request: Setting(text),
            since: conv.durable_frontier(),
          }),
        }),
      )
    }
    ClearGoal => {
      // Always send it, mirrored or not: the row lags the engine by one
      // durable commit, so a clear racing an in-flight set must not be
      // dropped on the mirror's say-so. A tombstone on a goalless session is
      // a harmless no-op the engine still confirms.
      //
      // The ✕ belongs to the conversation on screen, and so does the edit it
      // closes — neither can reach a neighbour's.
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      if conv.is_archived_read_only() {
        return (@cmd.none, model)
      }
      let (model, command) = model.allocate_submission_id()
      (
        send_goal(dispatch, model, conv, command, None),
        model.replace_conversation({
          ..conv,
          goal_edit: None,
          // Supersedes a set still awaiting its marker.
          goal_pending: Some({
            id: command,
            request: Clearing,
            since: conv.durable_frontier(),
          }),
        }),
      )
    }
    CloseGoalEditor => {
      guard model.active_conversation() is Some(conv) else {
        return (@cmd.none, model)
      }
      (@cmd.none, model.replace_conversation({ ..conv, goal_edit: None, }))
    }
    FileEditor(@fileeditor.GithubReview(CheckAvailability)) =>
      update_msg(dispatch, Github(@github.RefreshCurrent), model)
    FileEditor(@fileeditor.GithubReview(Refresh)) if !model.github.has_open_pr() =>
      update_msg(dispatch, Github(@github.RefreshCurrent), model)
    FileEditor(@fileeditor.UpdatePullRequest) => {
      guard model.file_panel.github_review.review is Some(review) &&
        model.file_panel.github_review.checkout is Some(checkout) &&
        model.github.scope == Some(checkout) &&
        !model.file_panel.github_review.busy else {
        return (@cmd.none, model)
      }
      update_msg(dispatch, Github(@github.UpdatePullRequest(review.url)), model)
    }
    FileEditor(msg) => {
      let preview = if msg
        is @fileeditor.StatsLoaded(owner~, epoch~, stats~, ..) &&
        model.file_panel.owner == Some(owner) &&
        model.file_panel.request_epoch == epoch {
        let mut preview = model.preview
        for stat in stats {
          preview = preview.observe_file(stat.path, stat.signature)
        }
        preview
      } else {
        model.preview
      }
      let model = { ..model, preview, }
      let (cmd, panel) = @fileeditor.update(
        dispatch.map(msg => FileEditor(msg)),
        msg,
        model.file_panel,
        file_ctx(model),
      )
      // The host can discover a closed/replaced PR while loading comments.
      // Feed that observation back through the one discovery owner. A retired
      // comment request must never invalidate a newer checkout's status.
      let github = if msg
        is @fileeditor.GithubReview(Loaded(epoch, Ok(ReviewLoaded(review)), _)) &&
        epoch == model.file_panel.github_review.epoch &&
        review.map(pr => pr.url) != model.github.current_url() {
        model.github.invalidate_current()
      } else {
        model.github
      }
      let next = { ..model, file_panel: panel, github, }
      let (reveal_cmd, next) = finish_review_context_load(
        dispatch,
        msg,
        model.file_panel,
        next,
      )
      if model.github.review_pending &&
        msg is @fileeditor.ChangesLoaded(owner~, generation~, files~, ..) &&
        model.file_panel.owner == Some(owner) &&
        model.file_panel.changes_generation == generation &&
        panel.changes_generation == generation &&
        panel.changes is ChangeListReady(refreshing=false, ..) {
        let next = {
          ..next,
          github: { ..next.github, review_pending: false, },
        }
        // Only the Review navigation initiated by checkout may open a file.
        // A newer user selection wins while the snapshot is being fetched.
        if next.dock.active is Some(FilePicker) &&
          next.file_panel.explorer_mode is ExplorerChanges &&
          files
          .iter()
          .filter(file => {
            !(file.kind is (ChangeUntracked | ChangeSubmodule | ChangeSymlink))
          })
          .next()
          is Some(change) {
          let (open_cmd, next) = update_msg(
            dispatch,
            FileEditor(ChangedFileSelected(change)),
            next,
          )
          return (@cmd.batch([cmd, reveal_cmd, open_cmd]), next)
        }
        (@cmd.batch([cmd, reveal_cmd]), next)
      } else {
        (@cmd.batch([cmd, reveal_cmd]), next)
      }
    }
    Dock(msg) => {
      // The strip machine is pure; the cross-package effects of the
      // transition — showing or dropping documents, mounting hosts — are
      // commanded here off the before/after difference.
      let before = model.dock
      let dock = @dock.update(msg, before)
      // Only a real non-empty -> empty strip transition closes the panel.
      // An already-empty panel is the launcher surface, so a stale close must
      // leave it open. Reset the other visibility bits just like the explicit
      // panel toggle does, keeping the root-owned panel state consistent.
      let model = if !before.tabs.is_empty() && dock.tabs.is_empty() {
        {
          ..model,
          dock,
          right_panel_open: false,
          right_panel_menu_open: false,
          right_panel_expanded: false,
        }
      } else {
        { ..model, dock, }
      }
      let femit = dispatch.map(msg => FileEditor(msg))
      match msg {
        TabActivated(_) =>
          if dock.active != before.active {
            // A tab selection is newer than any transcript link still waiting
            // on its host lookup, even when the selected tab is not a file.
            let model = model.begin_editor_navigation()
            if @dock.active_file(dock) is Some(path) {
              let cmds : Array[@cmd.Cmd] = []
              if @dock.active_file(before) is None {
                // The file body was CSS-hidden behind the browser pane or
                // the picker overlay; the viewer must re-measure its host on
                // return.
                cmds.push(@fileeditor.request_viewer_remeasure())
              }
              let (cmd, panel) = @fileeditor.activate(
                femit,
                model.file_panel,
                file_ctx(model),
                path,
              )
              cmds.push(cmd)
              (@cmd.batch(cmds), { ..model, file_panel: panel, })
            } else if @dock.active_history_diff(dock) is Some(diff) {
              let cmds : Array[@cmd.Cmd] = []
              if @dock.active_history_diff(before) is None {
                cmds.push(@fileeditor.request_viewer_remeasure())
              }
              let (cmd, panel) = @fileeditor.activate_history_diff(
                femit,
                model.file_panel,
                file_ctx(model),
                diff,
              )
              cmds.push(cmd)
              (@cmd.batch(cmds), { ..model, file_panel: panel, })
            } else {
              (@cmd.none, model)
            }
          } else {
            (@cmd.none, model)
          }
        TabClosed(tab) =>
          // A stale close (racing another close) leaves the strip — and so
          // the document table — untouched.
          if before.tabs.search_by(entry => entry == tab) is Some(_) {
            // When the closed tab was on screen and a file tab inherits it,
            // its document must be shown; a file close routes through
            // close_document (which also drops the document), the other
            // kinds activate directly.
            let next_file = @dock.active_file(dock)
            let next_history = @dock.active_history_diff(dock)
            let was_active = before.active is Some(active_tab) &&
              active_tab == tab
            // Closing any file tab is newer than a pending transcript link:
            // even an inactive tab must stay closed when that link's delayed
            // host lookup returns. Other tab kinds compete only when closing
            // them changes the active destination.
            let closes_file = match tab {
              File(_) | GitDiff(_) => true
              _ => false
            }
            let model = if closes_file ||
              (was_active && dock.active != before.active) {
              model.begin_editor_navigation()
            } else {
              model
            }
            match tab {
              File(path~) => {
                let (cmd, panel) = @fileeditor.close_document(
                  femit,
                  model.file_panel,
                  file_ctx(model),
                  path,
                  next=next_file,
                  was_active~,
                )
                if was_active && next_history is Some(diff) {
                  let (history_cmd, panel) = @fileeditor.activate_history_diff(
                    femit,
                    panel,
                    file_ctx(model),
                    diff,
                  )
                  (
                    @cmd.batch([cmd, history_cmd]),
                    { ..model, file_panel: panel, },
                  )
                } else {
                  (cmd, { ..model, file_panel: panel, })
                }
              }
              GitDiff(diff~) => {
                let panel = @fileeditor.close_history_diff(
                  model.file_panel,
                  diff,
                )
                if was_active && next_file is Some(path) {
                  let (cmd, panel) = @fileeditor.activate(
                    femit,
                    panel,
                    file_ctx(model),
                    path,
                  )
                  (cmd, { ..model, file_panel: panel, })
                } else if was_active && next_history is Some(next) {
                  let (cmd, panel) = @fileeditor.activate_history_diff(
                    femit,
                    panel,
                    file_ctx(model),
                    next,
                  )
                  (cmd, { ..model, file_panel: panel, })
                } else {
                  (@cmd.none, { ..model, file_panel: panel, })
                }
              }
              Browser(id~) => {
                let cmds : Array[@cmd.Cmd] = [browser_close_view(dispatch, id)]
                // Closing owns the native view's teardown. Retire its cached
                // placement at the same transition so the outer browser sync
                // does not enqueue a hide behind the close; the ordered bridge
                // lane would then try to hide a view the host already removed.
                // Clearing `geo` also makes a successor Browser tab re-measure.
                let browser_pane = if model.browser_pane.shown is Some(shown_id) &&
                  shown_id == id {
                  { shown: None, rect: None, geo: None, }
                } else {
                  model.browser_pane
                }
                let model = {
                  ..model,
                  preview: @preview.close_page(model.preview, id),
                  browser_pane,
                }
                if was_active && next_file is Some(path) {
                  cmds.push(@fileeditor.request_viewer_remeasure())
                  let (cmd, panel) = @fileeditor.activate(
                    femit,
                    model.file_panel,
                    file_ctx(model),
                    path,
                  )
                  cmds.push(cmd)
                  (@cmd.batch(cmds), { ..model, file_panel: panel, })
                } else if was_active && next_history is Some(diff) {
                  cmds.push(@fileeditor.request_viewer_remeasure())
                  let (cmd, panel) = @fileeditor.activate_history_diff(
                    femit,
                    model.file_panel,
                    file_ctx(model),
                    diff,
                  )
                  cmds.push(cmd)
                  (@cmd.batch(cmds), { ..model, file_panel: panel, })
                } else {
                  (@cmd.batch(cmds), model)
                }
              }
              // Neither tab owns a document: closing one while active hands
              // focus to a neighbouring file or diff, and otherwise nothing.
              FilePicker | Workflows | Jobs | Github =>
                if was_active && next_file is Some(path) {
                  let (cmd, panel) = @fileeditor.activate(
                    femit,
                    model.file_panel,
                    file_ctx(model),
                    path,
                  )
                  (cmd, { ..model, file_panel: panel, })
                } else if was_active && next_history is Some(diff) {
                  let (cmd, panel) = @fileeditor.activate_history_diff(
                    femit,
                    model.file_panel,
                    file_ctx(model),
                    diff,
                  )
                  (cmd, { ..model, file_panel: panel, })
                } else {
                  (@cmd.none, model)
                }
            }
          } else {
            (@cmd.none, model)
          }
      }
    }
    Preview(msg) => {
      // A navigation replaces the page realm, so reapply the app theme both
      // at commit time and after loading settles. The first call minimizes a
      // mismatched flash; the second covers engines whose document element
      // did not exist at the earlier event.
      let theme_cmd = match msg {
        @preview.Msg::Navigated(id~, ..) =>
          browser_set_theme(
            dispatch,
            id,
            model.theme.is_dark(model.system_dark),
          )
        @preview.Msg::LoadingChanged(id~, loading~) =>
          if loading {
            @cmd.none
          } else {
            browser_set_theme(
              dispatch,
              id,
              model.theme.is_dark(model.system_dark),
            )
          }
        _ => @cmd.none
      }
      let navigating = match msg {
        @preview.Msg::Navigated(id~, ..) => Some(id)
        @preview.Msg::LoadingChanged(id~, loading=true) => Some(id)
        _ => None
      }
      let (cancel_cmd, model) = if model.browser_annotation is Some(session) &&
        session.state is Selecting &&
        navigating == Some(session.id) {
        update_browser_annotation(dispatch, Cancel, model)
      } else {
        (@cmd.none, model)
      }
      (
        @cmd.batch([theme_cmd, cancel_cmd]),
        { ..model, preview: @preview.update(msg, model.preview), },
      )
    }
    BrowserAnnotation(msg) => update_browser_annotation(dispatch, msg, model)
    BrowserTabRequested => {
      let model = model.begin_editor_navigation()
      let (preview, id) = @preview.open_page(model.preview)
      let dock = @dock.open_browser(model.dock, id)
      (
        focus_browser_address(),
        { ..model, preview, dock, right_panel_menu_open: false, },
      )
    }
    ExplorerRequested(mode) => open_explorer(dispatch, model, mode)
    // The Workflows tab: opened like the explorer inventories, keeping the
    // right panel on screen with its launcher menu closed.
    Jobs(msg) => {
      let (cmd, jobs) = @jobs.update(
        locale=model.locale,
        dispatch.map(msg => Jobs(msg)),
        msg,
        model.jobs,
      )
      (cmd, { ..model, jobs, })
    }
    Github(msg) => {
      let completed = msg is @github.CheckedOut(epoch, _) &&
        epoch == model.github.checkout_epoch &&
        model.github.checking_out() &&
        !(msg is @github.CheckedOut(_, Ok(CheckoutNeedsConfirmation)))
      let succeeded = completed &&
        msg is @github.CheckedOut(_, Ok(CheckoutSuccess(_)))
      let enter_review = succeeded && model.github.active
      let (cmd, github) = @github.update(
        dispatch.map(msg => Github(msg)),
        msg,
        model.github,
      )
      let model = {
        ..model,
        github: if completed && !enter_review {
          { ..github, review_pending: false, }
        } else {
          github
        },
      }
      guard completed else { return (cmd, model) }
      let (git_cmd, model) = if model.screen is Codex {
        let (git_cmd, codex) = model.codex.refresh_git(
          dispatch.map(msg => Codex(channel=model.focused, msg)),
          model.focused,
        )
        (git_cmd, { ..model, codex, })
      } else if model.active_conversation() is Some(conv) {
        probe_branch(
          dispatch,
          model,
          conv.device,
          conv.session_id,
          model.conversation_root(conv),
        )
      } else {
        (@cmd.none, model)
      }
      let (review_cmd, model) = if enter_review {
        let model = {
          ..model,
          file_panel: {
            ..model.file_panel,
            github_review: {
              ..model.file_panel.github_review.reset_checkout(),
              enabled: true,
            },
          },
        }
        open_explorer(dispatch, model, ExplorerChanges)
      } else {
        (@cmd.none, model)
      }
      let (update_cmd, model) = if succeeded {
        update_msg(dispatch, FileEditor(@fileeditor.PullRequestUpdated), model)
      } else {
        (@cmd.none, model)
      }
      (@cmd.batch([cmd, git_cmd, review_cmd, update_cmd]), model)
    }
    GithubRequested =>
      (
        @cmd.none,
        {
          ..model,
          dock: @dock.open_github(model.dock),
          right_panel_open: true,
          right_panel_menu_open: false,
        },
      )
    JobsRequested =>
      (
        @cmd.none,
        {
          ..model,
          dock: @dock.open_jobs(model.dock),
          right_panel_open: true,
          right_panel_menu_open: false,
        },
      )
    WorkflowsRequested =>
      (
        @cmd.none,
        {
          ..model,
          dock: @dock.open_workflows(model.dock),
          right_panel_open: true,
          right_panel_menu_open: false,
        },
      )
    BrowserAddressEdited(value) =>
      match @dock.active_browser(model.dock) {
        Some(id) =>
          (
            @cmd.none,
            {
              ..model,
              preview: @preview.update(
                @preview.Msg::InputChanged(id~, value~),
                model.preview,
              ),
            },
          )
        None => (@cmd.none, model)
      }
    BrowserNavigateSubmitted => {
      guard @dock.active_browser(model.dock) is Some(id) &&
        @preview.page(model.preview, id) is Some(page) &&
        @preview.normalize_url(page.input) is Some(url) else {
        return (@cmd.none, model)
      }
      // A committed browser navigation is newer than any pending transcript
      // file link. Spend the token only after validation so an invalid address
      // draft remains a pure no-op.
      let model = model.begin_editor_navigation()
      // A blank tab's first navigation creates the native view; later ones
      // navigate the existing view.
      let (cmd, pane) = if page.url is Some(_) {
        // `browser.navigate` builds the view back when it is gone — a create
        // the host refused, or one a reload's `close_all` swept — and a
        // rebuilt view arrives hidden at a placeholder size. No view op is
        // acknowledged, so the cached placement may describe a view that
        // never existed; forgetting it has the next sync measure and place
        // whatever the host actually has now.
        (
          browser_navigate(
            dispatch,
            id,
            url,
            model.theme.is_dark(model.system_dark),
          ),
          { shown: None, rect: None, geo: None, },
        )
      } else {
        // The blank tab's own placement is already absent (a page without a
        // URL is never the desired view), so the create needs no reset.
        (
          browser_open(
            dispatch,
            id,
            url,
            model.theme.is_dark(model.system_dark),
          ),
          model.browser_pane,
        )
      }
      (
        cmd,
        {
          ..model,
          preview: @preview.navigate(model.preview, id, url),
          browser_pane: pane,
        },
      )
    }
    BrowserBack =>
      (
        browser_history_for_active(dispatch, model, @commands.browser_back),
        model,
      )
    BrowserForward =>
      (
        browser_history_for_active(dispatch, model, @commands.browser_forward),
        model,
      )
    BrowserReload =>
      (
        browser_history_for_active(dispatch, model, @commands.browser_reload),
        model,
      )
    BrowserOpenExternal => {
      guard @dock.active_browser(model.dock) is Some(id) &&
        @preview.page(model.preview, id) is Some(page) &&
        page.url is Some(url) else {
        return (@cmd.none, model)
      }
      (open_external_link(dispatch, url), model)
    }
    AppToggleMaximizedRequested =>
      if model.is_desktop {
        (
          browser_op(
            dispatch,
            @commands.app_toggle_maximized,
            @protocol.NoPayload,
            quiet=false,
          ),
          model,
        )
      } else {
        (@cmd.none, model)
      }
    AppDeveloperToolsRequested =>
      (
        browser_op(
          dispatch,
          @commands.app_open_devtools,
          @protocol.NoPayload,
          quiet=false,
        ),
        model,
      )
    AppCloseWindowRequested => {
      guard model.is_desktop else { return (@cmd.none, model) }
      (
        browser_op(
          dispatch,
          @commands.app_close_window,
          @protocol.NoPayload,
          quiet=false,
        ),
        model,
      )
    }
    CloseActiveDockTab => {
      guard model.is_desktop else { return (@cmd.none, model) }
      match model.dock.active {
        Some(tab) => {
          let (cmd, model) = update_msg(dispatch, Dock(TabClosed(tab)), model)
          (@cmd.batch([cmd, focus_dock_after_render()]), model)
        }
        None => (@cmd.none, model)
      }
    }
    BrowserPaneMeasured(rect~) => {
      // A rectangle for a view that already left the screen (or a zero
      // rectangle from the observer watching a hidden pane) is stale.
      guard desired_browser_view(model) is Some(id) &&
        rect.width > 0 &&
        rect.height > 0 else {
        return (@cmd.none, model)
      }
      let pane = model.browser_pane
      let cmds : Array[@cmd.Cmd] = []
      if pane.rect != Some(rect) || pane.shown != Some(id) {
        cmds.push(browser_set_bounds(dispatch, id, rect))
      }
      if pane.shown != Some(id) {
        // Bounds land before visibility so the view never flashes at its
        // previous place.
        if pane.shown is Some(old) {
          cmds.push(browser_set_visible(dispatch, old, false))
        }
        cmds.push(browser_set_visible(dispatch, id, true))
      }
      (
        @cmd.batch(cmds),
        {
          ..model,
          browser_pane: { ..pane, shown: Some(id), rect: Some(rect), },
        },
      )
    }
    Terminal(@terminal.LinkActivated(url~)) =>
      update_msg(dispatch, ExternalLinkClicked(url), model)
    Terminal(
      @terminal.CommandFinished(shell~, exit_code~, output~, truncated~) as msg
    ) => {
      // The panel sees it too: the result is read, so the tab can retire.
      let (retire, terminal) = model.terminal.handle(
        dispatch.map(next => Terminal(next)),
        msg,
        model.terminal_input(),
      )
      let (send, model) = shell_command_finished(
        dispatch,
        { ..model, terminal, },
        shell,
        exit_code,
        output,
        truncated,
      )
      (@cmd.batch([retire, send]), model)
    }
    Terminal(@terminal.CommandNotStarted(shell~, message~)) =>
      match model.conversation_by_shell(shell) {
        Some(conv) =>
          shell_not_started(
            dispatch,
            model,
            conv.device,
            conv.session_id,
            shell,
            message,
          )
        None => (@cmd.none, model)
      }
    RunShellCommand(channel~, session~, id~, command~, attempt~) =>
      run_shell_command(dispatch, model, channel, session, id, command, attempt)
    ShellNotStarted(channel~, session~, id~, message~) =>
      shell_not_started(dispatch, model, channel, session, id, message)
    Terminal(@terminal.InputFailed(message~)) =>
      model.notify_error(dispatch, message)
    Terminal(msg) => {
      let (cmd, terminal) = model.terminal.handle(
        dispatch.map(next => Terminal(next)),
        msg,
        model.terminal_input(),
      )
      (cmd, { ..model, terminal, })
    }
    HostActionFailed(message) => model.notify_error(dispatch, message)
    OpenExport(source) => {
      let (cmd, export_dialog) = model.export_dialog.open(source)
      (cmd, { ..model, export_dialog, })
    }
    ExportDialog(msg) => {
      let (cmd, export_dialog) = model.export_dialog.update(
        locale=model.locale,
        dispatch.map(next => ExportDialog(next)),
        msg,
      )
      (cmd, { ..model, export_dialog, })
    }
    ExternalLinkClicked(url) =>
      // Web links open in the dock's Browser tabs by default — the
      // toolbar's open-external button hands the page to the system
      // browser when its chrome or logins are needed. Non-web schemes
      // (mailto:, vscode:, …) and remote consoles (no native views) keep
      // the external path. A same-URL tab already in this strip
      // re-activates instead of duplicating.
      //
      // Only from conversation screens: the capture listener behind this
      // message is document-wide, so it also reports anchors on screens where
      // the dock is not rendered and a tab would be invisible. Chat and Codex
      // deliberately share this route — their PR links must open in the same
      // built-in Browser instead of changing behavior with the conversation
      // provider. Settings' device-page link is the clearest external case:
      // it wants the browser where the user is already signed in.
      if !model.is_desktop {
        (open_browser_link(url), model)
      } else if (model.screen is Chat || model.screen is Codex) &&
        @preview.is_web_url(url) {
        // Opening or reusing a Browser tab is a newer dock navigation than a
        // transcript text-file link still waiting on `host.open_path`. Spend the
        // shared token before either branch so its delayed reply cannot put a
        // file back over the URL the user chose later.
        let model = model.begin_editor_navigation()
        // The scan is over this strip's tabs, not the global page map: a
        // parked conversation may hold the same URL, and matching its page
        // first would shadow this strip's own tab forever.
        let reuse = for tab in model.dock.tabs {
          if tab is Browser(id~) &&
            @preview.page(model.preview, id) is Some(page) &&
            page.url is Some(page_url) &&
            page_url == url {
            break Some(id)
          }
        } nobreak {
          None
        }
        match reuse {
          Some(id) => {
            let dock = @dock.open_browser(model.dock, id)
            // The reuse matched this page's optimistic URL mirror, which can
            // drift from what the native view actually shows — a host op that
            // failed, or a reload's `close_all` that swept the view. Focusing
            // alone would present the stale page under the clicked URL, so a
            // reuse re-navigates: `browser.navigate` rebuilds the view when
            // it is gone, and dropping the pane placement makes the next sync
            // measure and show whatever the host has now.
            (
              browser_navigate(
                dispatch,
                id,
                url,
                model.theme.is_dark(model.system_dark),
              ),
              {
                ..model,
                preview: @preview.navigate(model.preview, id, url),
                dock,
                browser_pane: { shown: None, rect: None, geo: None, },
                right_panel_open: true,
                right_panel_menu_open: false,
              },
            )
          }
          None => {
            let (preview, id) = @preview.open_page(model.preview, url~)
            let dock = @dock.open_browser(model.dock, id)
            (
              browser_open(
                dispatch,
                id,
                url,
                model.theme.is_dark(model.system_dark),
              ),
              {
                ..model,
                preview,
                dock,
                right_panel_open: true,
                right_panel_menu_open: false,
              },
            )
          }
        }
      } else {
        (open_external_link(dispatch, url), model)
      }
    FromDevice(channel, msg) => update_device_msg(dispatch, channel, msg, model)
  }
}

///|
/// Settle one definitively refused initial prompt: restore its draft and
/// placement state, and report the refusal. Nothing durable will ever carry
/// it — the prompt was refused before anything was written — so it is a toast
/// rather than a transcript row.
fn Model::reject_start(
  self : Model,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  submission_id : String,
  message : String,
) -> (@cmd.Cmd, Model) {
  guard self.find_conversation(channel, session) is Some(conv) else {
    return (@cmd.none, self)
  }
  let (rejected, removed) = conv.reject_pending_prompt(submission_id)
  guard removed else { return (@cmd.none, self) }
  let next = if conv.run is Starting(submission_id=current) &&
    current == submission_id {
    { ..rejected.clear_streams(), run: NoRun(ended=Some(RunFailed)), }
  } else {
    rejected
  }
  let (notice, updated) = self
    .replace_conversation(next)
    .notify_error(dispatch, message)
  if updated.device_state(channel) is Some(dev) {
    // A checkout deleted outside the app cannot publish a registry
    // notification. Refresh placement after every rejected workspace start;
    // a newly missing row then exposes Repair/Archive immediately.
    let request_generation = dev.worktrees_request_generation + 1
    (
      @cmd.batch([
        notice,
        fetch_worktrees(
          dispatch,
          channel,
          conv.project(),
          dev.connection_generation,
          request_generation,
        ),
      ]),
      updated.replace_device({
        ..dev,
        worktrees_request_generation: request_generation,
      }),
    )
  } else {
    (notice, updated)
  }
}

///|
/// Reconcile the selected Codex task from one authoritative worktree registry
/// snapshot. List replies and live broadcasts have different freshness rules,
/// but once their caller accepts them they must project the same host-owned row
/// into Files, Terminal, language services, Git and skills.
fn Model::apply_codex_worktree_snapshot(
  self : Model,
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  workspace : @common.Uri,
  rows : Array[WorktreeRow],
) -> (@cmd.Cmd, Model) {
  guard channel == self.focused && self.codex.active_id() is Some(thread_id) else {
    return (@cmd.none, self)
  }
  for row in rows {
    if row.codex_thread is Some(thread) &&
      thread == thread_id &&
      row.path is Some(path) {
      let (command, codex) = @codex.update(
        locale=self.locale,
        dispatch.map(msg => Codex(channel~, msg)),
        @codex.Msg::worktree_changed(
          thread_id,
          workspace.path,
          row.name,
          path.path,
          row.present,
        ),
        self.codex,
        channel,
        url => open_external_link(dispatch, url),
      )
      return (command, { ..self, codex, })
    }
  }
  (@cmd.none, self)
}

///|
/// Catch up the transcript of a sub-run child the reader is looking at.
///
/// A child's record is written by a process the host manages no writer for, so
/// no follower broadcasts its commits (`backend/engine/follower` runs one per
/// host-managed writer) and `session.load` answered it with a one-shot read.
/// Every signal that the child moved therefore has to drive its own catch-up,
/// and there are exactly two: the probe's progress push while it runs, and the
/// finish. Both matter — the host cancels the probe at `subrun_finished`
/// without a final poll (`backend/engine/engine.mbt`), and the probe sleeps
/// before it reads, so the child's last writes — its report among them — reach
/// a reader through the finish or not at all.
///
/// `active_session` alone does not mean visible: a reader on Skills or
/// Settings has one, and reloading behind those screens would be work nobody
/// can see.
fn refresh_visible_subrun_child(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  session : String,
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.screen is Chat &&
    channel == model.focused &&
    session == model.active_session &&
    model.find_conversation(channel, session) is Some(child) &&
    model.can_reload_transcript(child) else {
    return (@cmd.none, model)
  }
  // Coalesce rather than drop. `begin_transcript_reload` is single-flight and
  // answers a signal arriving mid-read with `None`, which is right for a user
  // re-selecting a row and wrong here: the probe publishes only when the child
  // ADVANCED, so a dropped signal can be the last one ever sent — a child that
  // then finishes would strand this transcript one step short with nothing
  // left to correct it.
  let (next, generation) = model.ensure_transcript_reload_after_current(child)
  match generation {
    // A background refresh, never `activate_on_success`: the foreground path
    // pulls the UI to Chat, calls `Model::activate` (pruning other
    // conversations and clearing their unseen-finish marks), and remounts the
    // transcript component — and the remount is what would discard a reader's
    // scroll position and open disclosures. None of that belongs here.
    Some(generation) =>
      (
        session_snapshot_command(
          dispatch, channel, next, session, generation, false,
        ),
        next,
      )
    // Already reloading; the follow-up generation is now armed.
    None => (@cmd.none, next)
  }
}

///|
/// One device channel's messages — its connection lifecycle, its
/// notification stream, and every generation-fenced reply. The arms are
/// the same handlers `update_msg` held before the channel split; `channel`
/// names the device the message came from.
fn update_device_msg(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  msg : DeviceMsg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.device_state(channel) is Some(dev) else {
    return (@cmd.none, model)
  }
  match msg {
    InstalledSkillsLoaded(items) =>
      if channel == model.focused {
        (@cmd.none, { ..model, installed_skills: items, })
      } else {
        (@cmd.none, model)
      }
    InstalledSkillsFailed(message) =>
      if channel == model.focused {
        (
          @cmd.none,
          { ..model, skills: model.skills.with_library_error(message), },
        )
      } else {
        (@cmd.none, model)
      }
    // A running sub-run advanced. Two independent readers care: the PARENT's
    // dock lane, and — when the reader is looking at the child itself — the
    // CHILD's transcript. Neither is a precondition for the other. A lane
    // whose parent conversation is gone must not suppress the refresh of a
    // child on screen, and a child nobody is viewing must not suppress the
    // lane.
    // A resolved call of a workflow: refines the row its brackets created, or
    // creates one when they were missed. Routed like sub-run progress, by the
    // parent session the entry names; a conversation that is gone drops it.
    WorkflowEntryArrived(channel, entry) => {
      let model = match model.find_conversation(channel, entry.session) {
        Some(conv) =>
          model.replace_conversation({
            ..conv,
            workflows: @workflow.entry(conv.workflows, entry),
          })
        None => model
      }
      (@cmd.none, model)
    }
    SubrunProgressed(id~, session~, steps~, activity~) => {
      // Route by the CHILD session id, not by the sub-run id: `sr-N` is only
      // unique within its parent engine, so two conversations can both have
      // an `sr-1` in flight. The conversation on screen is not necessarily
      // the one that launched this child either — a background turn keeps
      // running while the user reads something else.
      //
      // An id with no lane is a push that outraced (or outlived) its
      // brackets — dropped, not resurrected, since only a bracket knows a
      // sub-run exists.
      let model = if @transcript.subrun_parent(session) is Some(parent) &&
        model.find_conversation(channel, parent) is Some(conv) {
        let subruns = conv.turn.subruns.map(lane => {
          if lane.id == id {
            { ..lane, steps, activity, }
          } else {
            lane
          }
        })
        if subruns == conv.turn.subruns {
          model
        } else {
          model.replace_conversation({
            ..conv,
            turn: { ..conv.turn, subruns, },
          })
        }
      } else {
        model
      }
      refresh_visible_subrun_child(dispatch, channel, session, model)
    }
    SkillsChanged =>
      if channel == model.focused {
        (fetch_installed_skills(dispatch, channel), model)
      } else {
        // `installed_skills` is the focused host's mirror. A background
        // device is refreshed when focus moves to it.
        (@cmd.none, model)
      }
    BridgeReady => {
      let connection_generation = dev.connection_generation + 1
      let sessions_request_generation = dev.sessions_request_generation + 1
      let archived_request_generation = dev.archived_request_generation + 1
      let projects_request_generation = dev.projects_request_generation + 1
      // Capture the exact per-session lifecycle frontier before issuing the
      // unversioned runs snapshot. A live Started or Finished received before
      // its reply then wins over both stale positive rows and stale absence.
      let run_frontier = model.run_snapshot_frontier(channel)
      let commands = [
        fetch_sessions(
          dispatch, channel, connection_generation, sessions_request_generation,
        ),
        // In-flight runs, so a page that joined (or reconnected) mid-run
        // learns each live run's identity — the resync half of the
        // protocol's reconnect story (docs/remote-protocol.md).
        fetch_runs(dispatch, channel, run_frontier, connection_generation),
        fetch_archived(
          dispatch, channel, connection_generation, archived_request_generation,
        ),
        fetch_projects(
          dispatch, channel, connection_generation, projects_request_generation,
        ),
      ]
      // The focused-scoped half: the host-settings mirror and installed
      // skills (they feed the composer's `$` completion, so
      // they load on connect rather than when the Skills page opens) follow
      // the device the UI acts on — always this one while the app runs a
      // single channel.
      if channel == model.focused {
        commands.push(
          fetch_host_settings(dispatch, channel, connection_generation),
        )
        commands.push(fetch_installed_skills(dispatch, channel))
        // Codex conversations are always visible in the global sidebar, so
        // populate that focused-host catalog on bridge readiness rather than
        // waiting for a separate Codex page to be opened.
        commands.push(dispatch(Codex(channel~, @codex.Msg::refresh())))
        // Self-update and the relay sign-in are the desktop window's alone
        // (see `is_desktop`); a browser never checks, so neither UI
        // materializes there. The startup update check rides here so it
        // only runs once the bridge can carry it.
        if model.is_desktop {
          commands.push(fetch_system_appearance(dispatch))
          commands.push(model.fetch_app_info(dispatch))
          commands.push(check_for_updates(dispatch, explicit=false))
          commands.push(
            @remote_access.fetch_status(dispatch.map(msg => RemoteAccess(msg))),
          )
        }
      }
      // Delta streams are not replayable across a connection boundary; keep
      // none of the pre-gap fragment, or the first post-gap delta would splice
      // onto stale text. Compaction has no wire resync in this protocol: an
      // local queued/requested/in-flight marker is released here so a missed
      // terminal event cannot disable Send forever. Any receipt still pending
      // at this boundary can no longer arrive, so its entry ends here. If the
      // host still compacts, its next prompt rejection is a transient,
      // visible local failure.
      let conversations = model.conversations.map(conv => {
        if conv.device == channel {
          {
            ..conv.clear_streams().forget_awaiting_inputs(),
            compaction: NotCompacting,
          }
        } else {
          conv
        }
      })
      let model = model.replace_device({
        ..dev,
        bridge: Connected,
        reconnect_failures: 0,
        connection_generation,
        sessions_request_generation,
        archived_request_generation,
        projects_request_generation,
        archive_overrides: [],
        // Worktree notifications are not replayed across a connection gap.
        // Keep every workspace blocked until this connection returns a fresh
        // list (or a newer `worktree.changed` broadcast) instead of trusting
        // placement cached before the disconnect.
        worktrees: [],
        // Same rule for the settings mirror: a default changed by another
        // client during the gap must not be copied into a chat created
        // before this connection's re-read lands. Absent rows read as the
        // safe Local default.
        workspace_settings: [],
      })
      // Replies from writes issued on the dead bridge carry their captured
      // generation and are ignored below. The new host may have restarted
      // its in-memory settings revision, so its first authoritative status
      // starts a fresh monotonic round. Focused-scoped, like the fetches
      // that repopulate the mirror.
      let model = if channel == model.focused {
        { ..model.clear_host_settings(), conversations, }
      } else {
        { ..model, conversations, }
      }
      // The resync's other half: whatever landed while this client was away
      // (another client's prompts, items a still-running turn completed, a
      // finished run's verdict) exists only in the store. Reads happen
      // exactly where this client was absent: the conversation on screen
      // re-reads now, every other one re-reads when opened (`OpenSession`
      // always reloads). An in-flight user load keeps right of way.
      let model = if channel == model.focused {
        match model.find_conversation(channel, model.active_session) {
          Some(conv) if (
              model.can_reload_transcript(conv) || conv.sync is Reloading(..)
            ) &&
            model.loading_conversation is None => {
            // A real engine pump can restart while the transport remains
            // open. If an older read is already in flight, it may carry a
            // pre-ready cut, so require one follow-up generation rather than
            // treating the old single-flight request as sufficient.
            let (model, generation) = model.ensure_transcript_reload_after_current(
              conv,
            )
            if generation is Some(generation) {
              commands.push(
                session_snapshot_command(
                  dispatch,
                  channel,
                  model,
                  conv.session_id,
                  generation,
                  false,
                ),
              )
            }
            model
          }
          _ => model
        }
      } else {
        model
      }
      guard channel == model.focused else {
        return (@cmd.batch(commands), model)
      }
      (
        @cmd.batch(commands),
        {
          // The host this bridge just (re)connected to may be a fresh
          // process with no filesystem watcher; forgetting what was watched
          // makes the post-dispatch panel sync re-issue `fs.watch` instead
          // of reading the stale record as "already placed". An unusable
          // endpoint does not route anywhere from here: the settings
          // snapshot this connection fetches decides whether the API-setup
          // modal opens.
          ..model,
          file_panel: { ..model.file_panel, watching: None, },
        },
      )
    }
    BridgeUnavailable(message) =>
      (@cmd.none, model.replace_device({ ..dev, bridge: BridgeLost(message), }))
    ChannelDown(websocket_epoch~) => {
      // A close callback may already be queued when sign-out retires a
      // device. If the same relay id is later re-added, it owns a new epoch
      // and must not inherit the retired connection's failure or timer.
      guard websocket_epoch == dev.websocket_epoch else {
        return (@cmd.none, model)
      }
      // Count the loss and schedule the next attempt. Because the attempt
      // comes back through this function, a removed or re-added device fails
      // the state/epoch guards and its old loop simply ends.
      let failures = dev.reconnect_failures + 1
      let bridge = if failures == WsLostAfter {
        BridgeLost(
          match model.locale {
            SimplifiedChinese =>
              "无法连接 SeekMoon。请确认 SeekMoon 正在运行，然后重新打开此页面。"
            TraditionalChinese =>
              "無法連線 SeekMoon。請確認 SeekMoon 正在執行，然後重新開啟此頁面。"
            Japanese =>
              "SeekMoon に接続できません。SeekMoon が起動していることを確認して、このページを開き直してください。"
            English =>
              "Can't reach SeekMoon. Make sure SeekMoon is running, then reopen this page."
            Spanish =>
              "No se puede conectar con SeekMoon. Comprueba que esté en ejecución y vuelve a abrir esta página."
          },
        )
      } else {
        dev.bridge
      }
      (
        @cmd.delay(
          dispatch(FromDevice(channel, ReconnectDue(websocket_epoch~))),
          reconnect_delay(failures),
        ),
        model.replace_device({ ..dev, bridge, reconnect_failures: failures, }),
      )
    }
    ReconnectDue(websocket_epoch~) => {
      guard websocket_epoch == dev.websocket_epoch else {
        return (@cmd.none, model)
      }
      (
        @cmd.none,
        model.replace_device({
          ..dev,
          reconnect_attempt: dev.reconnect_attempt + 1,
        }),
      )
    }
    FilePanel(msg) => {
      // The file panel serves the focused conversation; a background
      // device's fs/diagnostics noise must not re-stat or redraw it.
      guard channel == model.focused else { return (@cmd.none, model) }
      update_msg(dispatch, FileEditor(msg), model)
    }
    HostSettingsLoaded(settings, connection_generation~) => {
      guard connection_generation is None ||
        (connection_generation is Some(gen) && gen == dev.connection_generation) else {
        return (@cmd.none, model)
      }
      // The settings mirror is the focused host's. A generation-carrying
      // reply is only ever requested for the focused channel, but the
      // `settings.changed` broadcast (generation None) arrives from every
      // connected device — a background device's edit must not clobber the
      // form. A focus switch refetches, so nothing is lost.
      guard channel == model.focused else { return (@cmd.none, model) }
      if settings.revision < model.host_settings_revision {
        (@cmd.none, model)
      } else if model.settings_saves > 0 {
        (@cmd.none, model.defer_host_settings(settings))
      } else {
        // The settled mirror decides the modal (`settle_api_setup`); the
        // dismissal flag — not the mirror, which a reconnect clears — is
        // what keeps a "Not now" quiet across snapshots.
        (@cmd.none, model.apply_host_settings(settings).settle_api_setup())
      }
    }
    HostSettingsApplied(settings, connection_generation~) => {
      guard connection_generation == dev.connection_generation else {
        return (@cmd.none, model)
      }
      // A save issued on the old focus may settle after the user switches
      // devices. Its revision and localStorage cleanup belong to that old
      // host and must not alter the newly focused host's mirror.
      guard channel == model.focused else { return (@cmd.none, model) }
      let next = {
        ..model,
        settings_saves: if model.settings_saves > 0 {
          model.settings_saves - 1
        } else {
          0
        },
      }.defer_host_settings(settings)
      (
        @cmd.none,
        if next.settings_saves > 0 {
          next
        } else {
          next.flush_host_settings()
        },
      )
    }
    HostSettingsSaveFailed(message, connection_generation~) => {
      guard connection_generation == dev.connection_generation else {
        return (@cmd.none, model)
      }
      guard channel == model.focused else { return (@cmd.none, model) }
      let next = {
        ..model,
        settings_saves: if model.settings_saves > 0 {
          model.settings_saves - 1
        } else {
          0
        },
      }
      let next = if next.settings_saves == 0 {
        next.flush_host_settings()
      } else {
        next
      }
      let (notice, notified) = next.notify_error(
        dispatch,
        notice_text(model.locale, SaveSettings(message.to_string())),
      )
      let commands = [notice]
      if next.settings_saves == 0 {
        // No successful reply may follow to correct the optimistic form.
        // An authoritative get (same-revision statuses are accepted) restores
        // host truth after a definite or ambiguous write failure.
        commands.push(
          fetch_host_settings(dispatch, channel, dev.connection_generation),
        )
      }
      (@cmd.batch(commands), notified)
    }
    SteerUndelivered(session~, submission_id~, text~, run_id~) => {
      // The response path failed and the host may or may not have taken the
      // steer. Neither answer is knowable here and neither is worth guessing
      // at: the entry ends, and the transcript says what actually happened.
      ignore(text)
      if model.find_conversation(channel, session) is Some(conv) {
        let (next, changed) = conv.acknowledge_steer(
          submission_id,
          Some(run_id),
        )
        if changed {
          (@cmd.none, model.replace_conversation(next))
        } else {
          (@cmd.none, model)
        }
      } else {
        (@cmd.none, model)
      }
    }
    SteerRejected(session~, submission_id~, run_id~) =>
      // A concrete `steered:false` cannot later commit. Retire the queue entry
      // and restore its exact draft; a later same-text submission is unrelated.
      if model.find_conversation(channel, session) is Some(conv) {
        let (next, removed) = conv.reject_steer(submission_id, Some(run_id))
        if removed {
          model
          .replace_conversation(next)
          .notify_error(dispatch, SteerDroppedNotice)
        } else {
          (@cmd.none, model)
        }
      } else {
        (@cmd.none, model)
      }
    QueueAccepted(session~, action~, run_id~) => {
      guard model.find_conversation(channel, session) is Some(conv) else {
        return (@cmd.none, model)
      }
      let next = match action {
        @protocol.QueueAdd(id~, ..) => {
          let (next, _) = conv.acknowledge_steer(id, Some(run_id))
          next
        }
        @protocol.QueueEdit(id~, text=content, images~) => {
          guard conv.queued_inputs.search_by(item => item.id == id)
            is Some(index) else {
            return (@cmd.none, model)
          }
          let queued_inputs = conv.queued_inputs.copy()
          queued_inputs[index] = {
            id,
            content,
            images: images.map(url => { name: "Image", url, }),
          }
          if conv.queue_edit_id is Some(queued_id) && queued_id == id {
            {
              ..conv,
              queued_inputs,
              task: "",
              images: [],
              mentions: [],
              composer_draft_present: false,
              queue_edit_id: None,
            }
          } else {
            { ..conv, queued_inputs, }
          }
        }
        @protocol.QueueWithdraw(id~) | @protocol.QueueSteer(id~) => {
          let (next, _) = conv.remove_queued_input(id)
          next
        }
      }
      (@cmd.none, model.replace_conversation(next))
    }
    QueueAddRejected(session~, submission_id~, run_id~) =>
      if model.find_conversation(channel, session) is Some(conv) {
        let (next, removed) = conv.reject_steer(submission_id, Some(run_id))
        if removed {
          let (next, _) = next.remove_queued_input(submission_id)
          model
          .replace_conversation(next)
          .notify_error(
            dispatch,
            match model.locale {
              SimplifiedChinese =>
                "消息未加入队列（发送时任务已结束），已放回输入框。"
              TraditionalChinese =>
                "訊息未加入佇列（傳送時任務已結束），已放回輸入框。"
              Japanese =>
                "送信時にタスクが終了したため、メッセージをキューに追加せず入力欄に戻しました。"
              English =>
                "Message was not queued (the task ended as you sent it) — it is back in the composer."
              Spanish =>
                "El mensaje no se añadió a la cola (la tarea terminó mientras lo enviabas); está de nuevo en el cuadro de redacción."
            },
          )
        } else {
          (@cmd.none, model)
        }
      } else {
        (@cmd.none, model)
      }
    QueueSteerRejected(session~, submission_id~, run_id~, message~) =>
      if model.find_conversation(channel, session) is Some(conv) {
        let (next, removed) = conv.acknowledge_steer(
          submission_id,
          Some(run_id),
        )
        if removed {
          model.replace_conversation(next).notify_error(dispatch, message)
        } else {
          (@cmd.none, model)
        }
      } else {
        (@cmd.none, model)
      }
    CancelNotOpen(run_id~) => {
      guard model.conversation_by_run(channel, run_id) is Some(conv) else {
        return (@cmd.none, model)
      }
      // The id-addressed reply is authoritative: this exact run is no longer
      // open at the host. Close the optimistic Cancelling phase immediately,
      // then ask for the saved settlement so the ordinary Finished path can
      // recover its outcome and refresh the transcript. A successor that won
      // the race has another id and is left untouched by the guard above.
      let closed = conv.clear_streams().forget_steers_for_run(run_id)
      let closed = if closed.pending_approval
        is Some({ run_id: Some(owner), .. }) &&
        owner == run_id {
        { ..closed, pending_approval: None, }
      } else {
        closed
      }
      let updated = model.replace_conversation({
        ..closed,
        run: NoRun(ended=None),
        last_run_id: Some(run_id),
      })
      (
        fetch_runs(
          dispatch,
          channel,
          updated.run_snapshot_frontier(channel),
          dev.connection_generation,
        ),
        updated,
      )
    }
    CancelFailed(run_id~, message~) => {
      guard model.conversation_by_run(channel, run_id) is Some(conv) &&
        conv.run is Open(run_id=current, stage=Cancelling) &&
        current == run_id else {
        return (@cmd.none, model)
      }
      // Stop was optimistic. If delivery failed, hand the control back while
      // a runs snapshot determines whether the engine is in fact still live.
      let retryable = model.replace_conversation({
        ..conv,
        run: Open(run_id~, stage=AtStep(None)),
      })
      let (notice, notified) = retryable.notify_error(dispatch, message)
      (
        @cmd.batch([
          notice,
          fetch_runs(
            dispatch,
            channel,
            notified.run_snapshot_frontier(channel),
            dev.connection_generation,
          ),
        ]),
        notified,
      )
    }
    SessionsLoaded(items, connection_generation~, request_generation~) => {
      guard connection_generation == dev.connection_generation &&
        request_generation == dev.sessions_request_generation else {
        return (@cmd.none, model)
      }
      // Whole-list replies have no store revision. An identity notification
      // delivered after this request was issued wins for its session: remove
      // newly archived rows and retain newly unarchived rows from the current
      // model when the stale reply omitted them.
      let items = items.filter(item => {
        let disposition = dev.archive_override({
          session: item.id,
          workspace: item.workspace,
        })
        disposition != Some(ArchiveStored) &&
        disposition != Some(ArchiveDeleted)
      })
      for fact in dev.archive_overrides {
        if fact.disposition is ArchiveLive &&
          !items.any(item => fact.key.matches(item)) {
          for current in dev.sessions {
            if fact.key.matches(current) {
              items.push(current)
            }
          }
        }
      }
      // A commit or Started broadcast can materialize a conversation before
      // session.list tells this page which durable store owns it. Reconcile
      // that provisional placement from the list before any later send: an
      // empty workspace hint here would otherwise fork the same session into
      // the default store.
      let conversations = model.conversations.map(conv => {
        if conv.device == channel {
          let mut project = conv.project()
          for item in items {
            if item.id == conv.session_id {
              project = item.workspace
            }
          }
          {
            ..conv,
            workspace: dev.conversation_workspace(
              project,
              conv.session_id,
              conv.workspace,
            ),
          }
        } else {
          conv
        }
      })
      let mut active_project = dev.active_project
      if channel == model.focused {
        for item in items {
          if item.id == model.active_session {
            active_project = Some(item.workspace)
          }
        }
      }
      let mut next = {
        ..model.replace_device({ ..dev, sessions: items, active_project, }),
        conversations,
      }
      let commands : Array[@cmd.Cmd] = []
      // A client can miss session.changed while disconnected. A live row from
      // this connection is then the first proof that a cached read-only record
      // was restored elsewhere. Reclassify it before the archived-list reply:
      // the override admits new commits immediately, and the new transcript
      // generation fences the archived request started by BridgeReady.
      for conv in next.conversations {
        let key : ArchiveRecordKey = {
          session: conv.session_id,
          workspace: conv.project(),
        }
        if conv.device == channel &&
          conv.is_archived_read_only() &&
          items.any(item => key.matches(item)) {
          let foreground = channel == next.focused &&
            next.active_session == conv.session_id
          next = next.with_archive_override(channel, key, ArchiveLive)
          let (updated, generation) = next.begin_transcript_reload({
            ..conv,
            record: LiveRecord,
            sync: Synced,
          })
          next = if foreground {
            {
              ..updated,
              loading_conversation: Some({ channel, session: conv.session_id, }),
            }
          } else {
            updated
          }
          if generation is Some(generation) {
            commands.push(
              session_snapshot_command(
                dispatch,
                channel,
                next,
                conv.session_id,
                generation,
                foreground,
              ),
            )
          }
        }
      }
      // A start or a goal may have been accepted just before the connection
      // vanished, while the first BridgeReady load raced persistence and
      // returned empty. The session list is later durable proof that a record
      // now exists: use that edge to retry exactly the unresolved recoveries.
      for conv in next.conversations {
        if conv.device == channel &&
          conv.awaits_durable_proof() &&
          !(conv.sync is Reloading(..)) &&
          items.any(item => item.id == conv.session_id) {
          let (updated, generation) = next.begin_transcript_reload(conv)
          next = updated
          if generation is Some(generation) {
            commands.push(
              session_snapshot_command(
                dispatch,
                channel,
                next,
                conv.session_id,
                generation,
                false,
              ),
            )
          }
        }
      }
      (@cmd.batch(commands), next)
    }
    ProjectsLoaded(
      paths,
      connection_generation~,
      request_generation~,
      chat_root~
    ) => {
      guard connection_generation == dev.connection_generation &&
        request_generation == dev.projects_request_generation else {
        return (@cmd.none, model)
      }
      // The registry snapshot is also the authority for what this page may
      // keep open. `adopt_projects` drops conversations from detached
      // stores; their durable records remain on disk and return through the
      // next session list after the workspace is attached again.
      adopt_projects(
        dispatch,
        channel,
        model.replace_device({ ..dev, chat_root, }),
        paths,
      )
    }
    ProjectsChanged(paths, chat_root~) => {
      // The post-commit broadcast is newer than every list request issued so
      // far. Advance the token before applying it, so an older list reply can
      // never roll any client back after this canonical mutation order.
      let next = model.replace_device({
        ..dev,
        chat_root,
        projects_request_generation: dev.projects_request_generation + 1,
      })
      adopt_projects(dispatch, channel, next, paths)
    }
    ProjectAddCommitted(added~, paths~) => {
      // Identity resolution for a pending add-and-focus. This reply is the
      // canonical list right after our own commit, so the picked directory
      // is in it — as picked, or under its realpath spelling, in which case
      // it is the reply's one row we did not already know. Anything else
      // (concurrent commits landed between our known snapshot and ours) is
      // not provably ours: stand down rather than guess. `added` pairs the
      // reply with its confirm: a reply for a directory the pending is not
      // about answers a superseded confirm and is ignored outright — the
      // current confirm's own reply is still on its way.
      guard model.pending_project_adoption is Some(pending) &&
        pending.channel == channel &&
        pending.requested == added else {
        return (@cmd.none, model)
      }
      let target = if paths.contains(pending.picked) {
        Some(pending.picked)
      } else {
        match paths.filter(path => !pending.known.contains(path)) {
          [added] => Some(added)
          _ => None
        }
      }
      guard target is Some(target) else {
        return (@cmd.none, { ..model, pending_project_adoption: None, })
      }
      if dev.projects.contains(target) {
        // The commit broadcast beat this reply and the row already exists:
        // focus it now, the way the row's own ＋ does.
        let cleared = { ..model, pending_project_adoption: None, }
        let (focus_cmd, focused) = update(
          dispatch,
          NewChatIn(channel, Some(target)),
          cleared,
        )
        (@cmd.batch([focus_cmd, reveal_active_project()]), focused)
      } else {
        // The row is not on this page yet; the snapshot that brings it
        // finishes the focus.
        (
          @cmd.none,
          {
            ..model,
            pending_project_adoption: Some({
              ..pending,
              resolved: Some(target),
            }),
          },
        )
      }
    }
    ProjectFailed(message) => {
      // A failed mutation also settles any confirmed add still waiting to
      // focus its project: nothing was committed on its behalf.
      let model = if model.pending_project_adoption is Some(pending) &&
        pending.channel == channel {
        { ..model, pending_project_adoption: None, }
      } else {
        model
      }
      model.notify_error(
        dispatch,
        notice_text(model.locale, WorkspaceFailure(message.to_string())),
      )
    }
    WorkspaceSettingsLoaded(
      workspace~,
      worktree_mode~,
      checkout_submodules~,
      submodule_checkout_timeout_seconds~,
      connection_generation~,
      request_generation~
    ) => {
      // The same per-workspace staleness fence as `WorktreesLoaded` — plus a
      // registry-membership check, because pruning a detached workspace's
      // row also discards the generation it was applied under. Without the
      // membership check, a straggler reply issued before the detach would
      // pass the reset (-1) fence and resurrect a row that could outlive a
      // reattach until the fresh fan-out answers.
      guard dev.projects.contains(workspace) &&
        connection_generation == dev.connection_generation &&
        request_generation > dev.workspace_settings_generation(workspace) else {
        return (@cmd.none, model)
      }
      (
        @cmd.none,
        model.replace_device(
          dev.with_workspace_settings(
            workspace,
            worktree_mode,
            generation=request_generation,
            checkout_submodules~,
            submodule_checkout_timeout_seconds~,
          ),
        ),
      )
    }
    WorkspaceSettingsChanged(
      workspace~,
      worktree_mode~,
      checkout_submodules~,
      submodule_checkout_timeout_seconds~
    ) => {
      // A broadcast can race the detach commit the same way a reply can
      // (the hub orders them per client, so an attach is always processed
      // before settings broadcasts that follow it).
      guard dev.projects.contains(workspace) else { return (@cmd.none, model) }
      // The post-commit broadcast is newer than every list request issued so
      // far; advance the mint and stamp this workspace's row with the new
      // token so an older reply for it can never roll the broadcast back.
      let workspace_settings_request_generation = dev.workspace_settings_request_generation +
        1
      (
        @cmd.none,
        model.replace_device({
          ..dev.with_workspace_settings(
            workspace,
            worktree_mode,
            generation=workspace_settings_request_generation,
            checkout_submodules~,
            submodule_checkout_timeout_seconds~,
          ),
          workspace_settings_request_generation,
        }),
      )
    }
    WorkspaceSettingsSaveFinished(
      workspace~,
      connection_generation~,
      request_generation~,
      result~
    ) => {
      guard dev.projects.contains(workspace) &&
        connection_generation == dev.connection_generation else {
        return (@cmd.none, model)
      }
      match result {
        Ok(_) =>
          (
            @cmd.none,
            model.finish_workspace_settings_save(
              channel,
              workspace,
              request_generation,
              None,
            ),
          )
        Err(message) => {
          // Preserve the failure notification and authoritative re-read;
          // only the matching pending write may change dialog feedback.
          let reread_generation = dev.workspace_settings_request_generation + 1
          let message = notice_text(
            model.locale,
            SaveWorkspace(workspace.path.to_string(), message.to_string()),
          )
          let model = model.finish_workspace_settings_save(
            channel,
            workspace,
            request_generation,
            Some(message),
          )
          let (toast, next) = model.notify_error(dispatch, message)
          (
            @cmd.batch([
              toast,
              fetch_workspace_settings(
                dispatch,
                channel,
                workspace,
                dev.connection_generation,
                reread_generation,
              ),
            ]),
            next.replace_device({
              ..dev,
              workspace_settings_request_generation: reread_generation,
            }),
          )
        }
      }
    }
    WorktreesLoaded(
      rows,
      workspace~,
      connection_generation~,
      request_generation~
    ) => {
      // The staleness fence is per workspace: this reply is stale only when
      // THIS workspace's rows were already applied under a newer token — a
      // broadcast for a sibling workspace must not discard it.
      guard connection_generation == dev.connection_generation &&
        request_generation > dev.worktree_generation(workspace) else {
        return (@cmd.none, model)
      }
      let next_dev = dev.with_worktrees(
        workspace,
        rows,
        generation=request_generation,
      )
      let next = model.replace_device(next_dev)
      // A fresh list can be the first proof that a binding disappeared while
      // this client was disconnected. Spend one Git request number just like
      // the live broadcast path: every conversation unbound by this snapshot
      // must reject branch and pull-request answers still in flight for the
      // checkout that no longer owns it.
      let (fence, next) = next.mint_git_request()
      let conversations = next.conversations.map(conv => {
        if conv.device == channel && conv.project() == workspace {
          let placement = next_dev.conversation_workspace(
            workspace,
            conv.session_id,
            conv.workspace,
          )
          if conv.workspace is Worktree(..) && placement is Project(..) {
            { ..conv.forget_git(fence~), workspace: placement, }
          } else {
            { ..conv, workspace: placement, }
          }
        } else {
          conv
        }
      })
      // The list reply is the reconnect catch-up path: live
      // `worktree.changed` notifications are not replayed after a gap, so the
      // accepted snapshot must also repair the selected Codex task's placement.
      { ..next, conversations, }.apply_codex_worktree_snapshot(
        dispatch, channel, workspace, rows,
      )
    }
    WorktreesFailed(
      workspace~,
      connection_generation~,
      request_generation~,
      message~
    ) => {
      // A later snapshot or broadcast for this workspace makes an older
      // failure irrelevant, just as a dead connection's rejection must not
      // pop over the newly connected UI.
      guard connection_generation == dev.connection_generation &&
        request_generation > dev.worktree_generation(workspace) else {
        return (@cmd.none, model)
      }
      model.notify_error(
        dispatch,
        notice_text(
          model.locale,
          ListWorktrees(workspace.path.to_string(), message.to_string()),
        ),
      )
    }
    WorktreesChanged(rows, workspace~) => {
      // The post-commit broadcast is newer than every list request issued so
      // far; advance the mint and stamp this workspace's rows with the new
      // token so an older reply for it can never roll the broadcast back.
      let worktrees_request_generation = dev.worktrees_request_generation + 1
      let next_dev = {
        ..dev.with_worktrees(
          workspace,
          rows,
          generation=worktrees_request_generation,
        ),
        worktrees_request_generation,
      }
      let next = model.replace_device(next_dev)
      // Every conversation this broadcast unbinds is unbound at the same
      // instant, so one spent request number fences all of their probes.
      let (fence, next) = next.mint_git_request()
      // Only an actual registry-row removal unbinds its conversations. Archive
      // keeps the row with `present: false`, so it passes through unchanged and
      // later Unarchive still surfaces Repair. Stand down any staged confirm
      // only when the placement itself disappeared.
      let conversations = next.conversations.map(conv => {
        if conv.device == channel && conv.project() == workspace {
          let placement = next_dev.conversation_workspace(
            workspace,
            conv.session_id,
            conv.workspace,
          )
          if conv.workspace is Worktree(..) && placement is Project(..) {
            // The checkout is gone, so every placement derived from it goes
            // too. `forget_git` retires probes already in flight for the removed
            // checkout; the enum transition simultaneously makes every file,
            // LSP, terminal and launcher root re-project to the project.
            { ..conv.forget_git(fence~), workspace: placement, }
          } else {
            { ..conv, workspace: placement, }
          }
        } else {
          conv
        }
      })
      // An open discard dialog whose mapping just disappeared (a protocol
      // client explicitly removed the worktree) must close too:
      // confirming it later would fire a stale forced archive.
      let archive_confirm = match next.archive_confirm {
        Some(confirm) if confirm.channel == channel &&
          next.find_conversation(channel, confirm.session) is Some(conv) &&
          conv.project() == workspace &&
          !rows.any(row => {
            row.session is Some(session) && session == confirm.session
          }) => None
        other => other
      }
      let next = { ..next, conversations, archive_confirm, }
      // `worktree.create` commits and broadcasts the owner row before the
      // initiating frontend receives its turn reply. Apply the same accepted
      // snapshot transition as reconnect, so every frontend displaying this
      // Codex task moves its native roots together.
      next.apply_codex_worktree_snapshot(dispatch, channel, workspace, rows)
    }
    WorktreeCreated(workspace~, name~, session~) => {
      // The chain's checkout exists: bind the composing conversation, so
      // the chip shows and a retried submit reuses the same environment.
      guard model.find_conversation(channel, session) is Some(conv) &&
        conv.workspace is Project(root=current) &&
        current == workspace else {
        return (@cmd.none, model)
      }
      (
        @cmd.none,
        model.replace_conversation({
          ..conv,
          workspace: Worktree(project=workspace, name~),
          worktree_mode: false,
        }),
      )
    }
    ArchiveNeedsForce(session~, refusal~) =>
      // The host refused to archive over the worktree's uncommitted
      // changes; stage the discard-confirmation dialog, whose confirm
      // retries with force.
      (
        @cmd.none,
        { ..model, archive_confirm: Some({ channel, session, refusal, }), },
      )
    ArchivedLoaded(
      items,
      connection_generation~,
      request_generation~,
      fresh_session~
    ) => {
      guard connection_generation == dev.connection_generation &&
        request_generation == dev.archived_request_generation else {
        return (@cmd.none, model)
      }
      // A newer unarchive notification wins over an older whole-list reply;
      // a newer archive notification is supplemented from the current list
      // when that reply predates the move.
      let items = items.filter(item => {
        let disposition = dev.archive_override({
          session: item.id,
          workspace: item.workspace,
        })
        disposition != Some(ArchiveLive) && disposition != Some(ArchiveDeleted)
      })
      for fact in dev.archive_overrides {
        if fact.disposition is ArchiveStored &&
          !items.any(item => fact.key.matches(item)) {
          for current in dev.archived {
            if fact.key.matches(current) {
              items.push(current)
            }
          }
        }
      }
      // An archive mutation response can beat its session.changed callback.
      // Treat a newly observed archived row as a local tombstone immediately,
      // so a stale live-list reply cannot reopen it in that delivery gap.
      let mut next = model
      for item in items {
        let key : ArchiveRecordKey = {
          session: item.id,
          workspace: item.workspace,
        }
        if next.archive_override(channel, key) is None {
          next = next.with_archive_override(channel, key, ArchiveStored)
        }
      }
      let archived_now = (id : String, workspace : @common.Uri) => {
        items.any(item => item.id == id && item.workspace == workspace)
      }
      // The selected row may still be loading while another conversation is
      // active. Its exact store-qualified identity, not `active_session`, owns
      // the fallback when an archive reply removes it.
      if next.conversation_selection() is Some(selected) &&
        selected.record is LiveRecord &&
        archived_now(selected.session, selected.workspace) {
        next = replace_removed_selection(
          next,
          channel,
          selected.session,
          fresh_session,
          selected.workspace,
          LiveRecord,
        )
      }
      let conversations = next.conversations.filter(conv => {
        conv.device != channel ||
        !archived_now(conv.session_id, conv.project()) ||
        conv.is_archived_read_only()
      })
      guard next.device_state(channel) is Some(ndev) else {
        return (@cmd.none, { ..next, conversations, })
      }
      let sessions = ndev.sessions.filter(item => {
        !archived_now(item.id, item.workspace)
      })
      (
        @cmd.none,
        {
          ..next.replace_device({ ..ndev, archived: items, sessions, }),
          conversations,
        },
      )
    }
    ArchivedDeleted(
      key~,
      sessions~,
      items~,
      connection_generation~,
      request_generation~,
      fresh_session~
    ) => {
      guard connection_generation == dev.connection_generation &&
        request_generation == dev.archived_request_generation else {
        return (@cmd.none, model)
      }
      // Install the permanent tombstone before folding the unversioned list
      // reply. The ordinary ArchivedLoaded reconciliation then rejects both
      // this stale row and any later live-list copy of it.
      let mut tombstoned = model
      for session in sessions {
        tombstoned = tombstoned.with_archive_override(
          channel,
          { session, workspace: key.workspace, },
          ArchiveDeleted,
        )
      }
      // The selected archived row may still be loading. Replace that exact
      // selection before removing its backing conversation.
      if tombstoned.conversation_selection() is Some(selected) &&
        selected.record is ArchivedRecord &&
        selected.channel == channel &&
        selected.workspace == key.workspace &&
        sessions.contains(selected.session) {
        tombstoned = replace_removed_selection(
          tombstoned,
          channel,
          selected.session,
          fresh_session,
          key.workspace,
          ArchivedRecord,
        )
      }
      if tombstoned.device_state(channel) is Some(ndev) {
        tombstoned = tombstoned.replace_device({
          ..ndev,
          sessions: ndev.sessions.filter(item => {
            item.workspace != key.workspace || !sessions.contains(item.id)
          }),
          archived: ndev.archived.filter(item => {
            item.workspace != key.workspace || !sessions.contains(item.id)
          }),
        })
      }
      let conversations = tombstoned.conversations.filter(conv => {
        conv.device != channel ||
        conv.project() != key.workspace ||
        !sessions.contains(conv.session_id)
      })
      update_device_msg(
        dispatch,
        channel,
        ArchivedLoaded(
          items,
          connection_generation~,
          request_generation~,
          fresh_session~,
        ),
        { ..tombstoned, conversations, archived_delete_confirm: None, },
      )
    }
    ArchiveFailed(message) => {
      // A definitive refusal usually means this page no longer matches the
      // host's stores — the record moved, or its workspace detached while
      // this sidebar still showed it. Re-adopt the registry snapshot (which
      // prunes detached conversations and refreshes the live list) and the
      // archived list, so the state that made the click possible heals
      // instead of failing identically forever.
      let projects_request_generation = dev.projects_request_generation + 1
      let refresh = fetch_projects(
        dispatch,
        channel,
        dev.connection_generation,
        projects_request_generation,
      )
      let model = model.replace_device({ ..dev, projects_request_generation, })
      let (archived, model) = request_archived_refresh(dispatch, channel, model)
      let (toast, model) = model.notify_error(
        dispatch,
        notice_text(model.locale, ArchiveFailure(message.to_string())),
      )
      (@cmd.batch([refresh, archived, toast]), model)
    }
    DeleteArchivedFailed(message) => {
      let (refresh, model) = request_archived_refresh(dispatch, channel, model)
      let (toast, model) = model.notify_error(
        dispatch,
        notice_text(model.locale, DeleteFailure(message.to_string())),
      )
      (@cmd.batch([refresh, toast]), model)
    }
    WorktreeFailed(message) => model.notify_error(dispatch, message)
    SessionsFailed(message) =>
      model.notify_error(
        dispatch,
        notice_text(model.locale, ListSessions(message.to_string())),
      )
    // Another client archived, restored, or deleted a conversation. Both
    // sidebar lists are stale, but this identity-bearing fact takes effect
    // immediately and remains authoritative over in-flight replies.
    SessionsChanged(change~, key~, fresh_session~) => {
      let (sessions, model) = request_sessions_refresh(dispatch, channel, model)
      let (archived, model) = request_archived_refresh(dispatch, channel, model)
      let (schedules, model) = if model.wants_schedule_updates() &&
        model.focused == channel {
        request_schedules(dispatch, model, List)
      } else {
        (@cmd.none, model)
      }
      let commands = @cmd.batch([sessions, archived, schedules])
      guard model.device_state(channel) is Some(dev) else {
        return (commands, model)
      }
      if change == "deleted" {
        let changed = if fresh_session is Some(fresh) {
          replace_removed_selection(
            model,
            channel,
            key.session,
            fresh,
            key.workspace,
            ArchivedRecord,
          )
        } else {
          model
        }
        let sessions = dev.sessions.filter(item => !key.matches(item))
        let archived = dev.archived.filter(item => !key.matches(item))
        let conversations = changed.conversations.filter(conv => {
          conv.device != channel ||
          conv.session_id != key.session ||
          conv.project() != key.workspace
        })
        let confirm = match changed.archived_delete_confirm {
          Some(confirm) if confirm.channel == channel && confirm.key == key =>
            None
          other => other
        }
        let next = changed
          .replace_device({ ..dev, sessions, archived, })
          .with_archive_override(channel, key, ArchiveDeleted)
        return (
          commands,
          { ..next, conversations, archived_delete_confirm: confirm, },
        )
      }
      if change == "unarchived" {
        let mut restored : @transcript.SessionListItem? = None
        for item in dev.archived {
          if key.matches(item) {
            restored = Some(item)
          }
        }
        let archived = dev.archived.filter(item => !key.matches(item))
        let sessions = dev.sessions.copy()
        if restored is Some(item) &&
          !sessions.any(current => key.matches(current)) {
          sessions.push(item)
        }
        let next = model
          .replace_device({ ..dev, sessions, archived, })
          .with_archive_override(channel, key, ArchiveLive)
        let next = match next.selected_conversation {
          Some(selected) if selected.matches_record(
              channel,
              key.session,
              key.workspace,
              ArchivedRecord,
            ) =>
            {
              ..next,
              selected_conversation: Some({ ..selected, record: LiveRecord, }),
            }
          _ => next
        }
        // Fence an archived read that was already in flight, then re-read the
        // now-live record. The transcript stays visible while this new
        // generation settles; only the record source and composer capability
        // change immediately.
        if next.find_conversation(channel, key.session) is Some(conv) &&
          conv.project() == key.workspace &&
          conv.is_archived_read_only() {
          let (next, generation) = next.begin_transcript_reload({
            ..conv,
            record: LiveRecord,
            sync: Synced,
          })
          if generation is Some(generation) {
            let foreground = channel == next.focused &&
              next.active_session == key.session &&
              next.session_project(channel, key.session)
              is Some(session_workspace) &&
              session_workspace == key.workspace
            let next = if foreground {
              {
                ..next,
                loading_conversation: Some({ channel, session: key.session, }),
              }
            } else {
              next
            }
            return (
              @cmd.batch([
                commands,
                session_snapshot_command(
                  dispatch,
                  channel,
                  next,
                  key.session,
                  generation,
                  foreground,
                ),
              ]),
              next,
            )
          }
          return (commands, next)
        }
        return (commands, next)
      }
      if change != "archived" {
        return (commands, model)
      }
      // Invalidate the live target before either async list reply. Keeping a
      // placeholder archived entry also blocks a late session.event from
      // rematerializing it during this window.
      let sessions = dev.sessions.filter(item => !key.matches(item))
      let conversations = model.conversations.filter(conv => {
        conv.device != channel ||
        conv.session_id != key.session ||
        conv.project() != key.workspace ||
        conv.is_archived_read_only()
      })
      let archived = dev.archived.copy()
      if !archived.any(item => key.matches(item)) {
        let mut item : @transcript.SessionListItem = {
          id: key.session,
          title: None,
          workspace: key.workspace,
          workspace_name: "",
          updated_at_ms: None,
        }
        for live in dev.sessions {
          if key.matches(live) {
            item = live
          }
        }
        archived.push(item)
      }
      let overridden = model.with_archive_override(channel, key, ArchiveStored)
      let overridden = match overridden.device_state(channel) {
        Some(ndev) => overridden.replace_device({ ..ndev, sessions, archived, })
        None => overridden
      }
      let selected_archived = model.conversation_selection() is Some(selected) &&
        selected.matches_record(channel, key.session, key.workspace, LiveRecord)
      let next = {
        ..overridden,
        conversations: if selected_archived {
          model.conversations
        } else {
          conversations
        },
      }
      if selected_archived && fresh_session is Some(fresh) {
        (
          commands,
          replace_removed_selection(
            next,
            channel,
            key.session,
            fresh,
            key.workspace,
            LiveRecord,
          ),
        )
      } else {
        (commands, { ..next, conversations, })
      }
    }
    SessionLoaded(
      session~,
      items~,
      watermark~,
      goal~,
      goal_markers~,
      prediction~,
      generation~
    ) =>
      apply_session_snapshot(
        dispatch, channel, model, session, items, watermark, goal, goal_markers,
        generation, true, prediction,
      )
    SessionRefreshed(
      session~,
      items~,
      watermark~,
      goal~,
      goal_markers~,
      prediction~,
      generation~
    ) =>
      apply_session_snapshot(
        dispatch, channel, model, session, items, watermark, goal, goal_markers,
        generation, false, prediction,
      )
    SessionLoadFailed(session~, message~, generation~) =>
      retry_session_snapshot(
        dispatch, channel, model, session, generation, true, message,
      )
    SessionRefreshFailed(session~, generation~) =>
      retry_session_snapshot(
        dispatch,
        channel,
        model,
        session,
        generation,
        false,
        "failed to refresh session \{session}",
      )
    PredictionReceived(session~, prediction~) =>
      if model.find_conversation(channel, session) is Some(conv) {
        (
          @cmd.none,
          model.replace_conversation(conv.with_prediction(Some(prediction))),
        )
      } else {
        (@cmd.none, model)
      }
    SessionCommitted(session~, sequence~, ts~, item~, session_root~) => {
      // The commit names its own store — the exact durable identity rather
      // than a guess. Commits do not precede `agent.connected` (readiness
      // precedes every forwarded notification), but if one ever did, the
      // listing/live guess is what places it.
      //
      // A store this page cannot resolve to a project places nothing: the
      // record could not be told apart from a same-id one in another store,
      // so the commit is dropped rather than attached to a guess.
      guard (match dev.bridge {
          Connected => dev.placement_for_store_root(session_root)
          _ => model.session_project(channel, session)
        })
        is Some(commit_project) else {
        return (@cmd.none, model)
      }
      // Archiving removes live client state after the hub's ordered final
      // commit. A stale/replayed commit seen after that local fact must not
      // resurrect the archived record as a live hidden conversation.
      let key : ArchiveRecordKey = { session, workspace: commit_project, }
      let archived = match dev.archive_override(key) {
        Some(ArchiveStored | ArchiveDeleted) => true
        Some(ArchiveLive) => false
        None => dev.archived.any(item => key.matches(item))
      }
      if archived {
        return (@cmd.none, model)
      }
      // The page holds at most one conversation per (channel, id), so the
      // one this id finds may stand for another store's record — and that
      // record's watermark says nothing about this store's commits. Only a
      // conversation placed in the committed store can have seen them.
      let first_commit_unseen = match
        model.find_conversation(channel, session) {
        Some(conv) if conv.project() == commit_project =>
          !conv.has_seen_durable_sequence(sequence)
        _ => true
      }
      // The listing is store-qualified, so ask whether THIS record is listed:
      // a same-id row from another store is a different durable record and
      // must not suppress the reload that gives this one its sidebar row.
      let listed = dev.sessions.any(item => {
        item.id == session && item.workspace == commit_project
      })
      let refresh_sessions = sequence == 1 && !listed && first_commit_unseen
      // A short foreign run can commit and finish before either the session
      // list or run resync reaches this page. Materialize hidden client state
      // from the commit itself: sequence 1 projects immediately; a later
      // sequence exposes a gap and follows the normal snapshot recovery path.
      let model = if model.find_conversation(channel, session) is None {
        model.replace_conversation(
          empty_conversation(
            channel,
            session,
            commit_project,
            model=model
              .remembered_model(channel, session)
              .unwrap_or(model.default_model),
          ),
        )
      } else {
        model
      }
      let (commit_cmd, next) = if model.find_conversation(channel, session)
        is Some(conv) {
        let commit : BufferedCommit = { sequence, ts, item, }
        match conv.sync {
          // A read is in flight: buffer — its snapshot's watermark decides
          // whether this commit is already contained once it lands.
          Reloading(..) =>
            (@cmd.none, model.replace_conversation(conv.buffer_commit(commit)))
          // A new commit is also a retry signal after a bounded round stopped.
          ReloadFailed(..) => {
            let (model, generation) = model.begin_transcript_reload(
              conv.buffer_commit(commit),
            )
            if generation is Some(generation) {
              (
                session_snapshot_command(
                  dispatch, channel, model, session, generation, false,
                ),
                model,
              )
            } else {
              (@cmd.none, model)
            }
          }
          Synced =>
            if sequence <= conv.watermark {
              // Old news: the snapshot (or an earlier commit) already
              // carried it. Re-broadcasts are safe by construction.
              (@cmd.none, model)
            } else if sequence == conv.watermark + 1 {
              let (changed, next) = conv.apply_commit(sequence, item, ts?)
              (
                if changed {
                  @cmd.none
                } else {
                  @cmd.none
                },
                model.replace_conversation({ ..next, watermark: sequence, }),
              )
            } else {
              // A gap: this client missed a broadcast (kicked as a slow
              // subscriber, a host restart, an external writer). The record
              // is the source of truth — re-read it, buffering from here.
              let (model, generation) = model.begin_transcript_reload(conv)
              guard model.find_conversation(channel, session) is Some(reloading) else {
                return (@cmd.none, model)
              }
              let model = model.replace_conversation(
                reloading.buffer_commit(commit),
              )
              if generation is Some(generation) {
                (
                  session_snapshot_command(
                    dispatch, channel, model, session, generation, false,
                  ),
                  model,
                )
              } else {
                (@cmd.none, model)
              }
            }
        }
      } else {
        (@cmd.none, model)
      }
      // A live Started can overtake the store write and the BridgeReady list
      // request can therefore miss a newly-created session. Sequence one is
      // the first durable proof that the record exists; refresh the list so
      // clients that learned the commit first still converge on the store's
      // project grouping.
      if refresh_sessions {
        let (sessions, next) = request_sessions_refresh(dispatch, channel, next)
        (@cmd.batch([commit_cmd, sessions]), next)
      } else {
        (commit_cmd, next)
      }
    }
    BranchLoaded(session~, branch~, diffstat~, generation~, base_hint~) => {
      guard model.find_conversation(channel, session) is Some(conv) else {
        return (@cmd.none, model)
      }
      // A probe that is still counting untracked files while a later one has
      // already answered would otherwise put its older branch and totals back
      // on screen, where nothing would correct them until the next refresh.
      guard generation == conv.branch_generation else {
        return (@cmd.none, model)
      }
      let conv = { ..conv, branch, diffstat, diffstat_hint: base_hint, }
      // The pull-request lookup rides on the branch answer rather than on the
      // four places that ask for it: whatever refreshes the branch — a run
      // starting, a session opening, a run finishing — is exactly when the
      // branch's pull request can have changed too.
      guard branch is Some(branch) && !branch.is_empty() else {
        // Not a repository any more: an answer about the branch it used to
        // have would only mislead, including one still on its way.
        let (fence, model) = model.mint_git_request()
        return (
          @cmd.none,
          model.replace_conversation(conv.forget_pull_request(fence~)),
        )
      }
      // A lookup already in flight for this same branch is not stacked on —
      // but it is marked stale, because its answer was gathered before this
      // refresh asked for one. Dropping the refresh outright would leave the
      // chip describing the repository as it was when a run started, with
      // nothing scheduled to correct it.
      if conv.pull_request is Some(probe) &&
        probe.probing &&
        probe.branch == branch {
        let pull_request = Some({ ..probe, stale: true, })
        return (
          @cmd.none,
          model.replace_conversation({ ..conv, pull_request, }),
        )
      }
      probe_pull_request(dispatch, model, channel, conv, branch)
    }
    PullRequestLoaded(
      session~,
      branch~,
      generation~,
      queried~,
      pull_request~,
      compare_url~
    ) => {
      guard model.find_conversation(channel, session) is Some(conv) else {
        return (@cmd.none, model)
      }
      // Matched by which request this answers, not by branch: a checkout that
      // moves X → Y → X leaves two lookups for X in flight, and if the newer
      // settles first, matching by name would let the older overwrite it.
      guard generation == conv.pull_request_generation else {
        return (@cmd.none, model)
      }
      // Read before the answer overwrites it: whether a refresh landed while
      // this lookup was in flight.
      let stale = conv.pull_request is Some(probe) && probe.stale
      // Labelled with the branch the host actually read from `HEAD`. When the
      // checkout moved mid-flight the two differ, and the answer is filed
      // under what it describes — where `settled_probe` hides it until the
      // branch chip catches up, instead of showing it against this one.
      let settled : PullRequestProbe = {
        branch: queried.unwrap_or(branch),
        probing: false,
        stale: false,
        pull_request,
        compare_url,
      }
      let conv = { ..conv, pull_request: Some(settled), }
      // A refresh arrived while this lookup was in flight: its answer predates
      // that refresh, so run one more against the branch now checked out.
      if stale && conv.branch is Some(current) && !current.is_empty() {
        return probe_pull_request(dispatch, model, channel, conv, current)
      }
      let model = model.replace_conversation(conv)
      // This answer may have named a base nobody knew when the diffstat beside
      // it was measured — the first pull request a session sees, or one that
      // has been retargeted since. Until it is measured again the popover
      // reports a span from the wrong place, which on a stacked pull request
      // is not a rounding error but the whole branch below this one. Measuring
      // again settles the hint, so this asks at most once per base.
      guard conv.settled_probe() is Some(probe) &&
        probe.pull_request is Some(answer) &&
        conv.diffstat_hint != Some(answer.base) else {
        return (@cmd.none, model)
      }
      probe_branch(
        dispatch,
        model,
        channel,
        session,
        model.conversation_root(conv),
      )
    }
    Started(
      run_id~,
      session~,
      model=selected_model,
      max_steps~,
      session_root~,
      submission_id~
    ) => {
      // This run's durable store, classified exactly the way a commit's root
      // is: Started precedes the first commit, so on a fresh connection this
      // is the placement the conversation is born with — and the projects
      // registry it would otherwise be resolved against may still be in
      // flight. A rootless legacy event has no store to classify.
      let started_project = if dev.bridge is Connected &&
        session_root is Some(root) {
        dev.placement_for_store_root(root)
      } else {
        dev.project_for_session_root(session_root)
      }
      // A delete tombstone outranks unversioned list replies and replayed
      // commits, but it must not hide a later same-id incarnation forever.
      // Started precedes every commit of an accepted run and carries the
      // host-selected durable store, so it is the first exact creation fact
      // that can safely retire the tombstone. Rootless legacy events cannot
      // distinguish same-id records in different stores and leave it intact.
      let model = match (session_root, started_project) {
        (Some(_), Some(workspace)) => {
          let key : ArchiveRecordKey = { session, workspace, }
          if dev.archive_override(key) is Some(ArchiveDeleted) {
            model.with_archive_override(channel, key, ArchiveLive)
          } else {
            model
          }
        }
        _ => model
      }
      // A run another client started may reach us with no local conversation
      // for its session (an `agent.runs` resync on a fresh page, or a live
      // start for a session this client never opened): materialize one, so
      // the run is trackable — streamable, cancellable, steerable — from
      // every client, not just the one that sent the prompt. A run this
      // client sent is already `Starting` when its `started` arrives (the
      // send handler flips the phase before the request leaves). Repeating
      // the same open id is idempotent; a distinct id replacing a stale open
      // run is foreign and first settles that old run's transient state.
      let existing = match model.find_conversation(channel, session) {
        Some(conv) => conv
        None => {
          // A conversation is created inside a project. With neither the
          // run's own store nor a listing to place this session, there is no
          // directory to track it in and no store to read it from, so the
          // run is left alone rather than materialized nowhere.
          guard (match started_project {
              Some(project) => Some(project)
              None => model.session_project(channel, session)
            })
            is Some(project) else {
            return (@cmd.none, model)
          }
          empty_conversation(
            channel,
            session,
            project,
            // A conversation this page is meeting for the first time takes
            // the tier its run is on — better evidence than the default,
            // and no choice exists yet to contradict it. A remembered choice
            // still outranks it: that is what the user meant to send next,
            // while the run may have been started elsewhere. A conversation
            // the page already holds keeps its own tier — see below.
            model=model
              .remembered_model(channel, session)
              .unwrap_or(selected_model),
          )
        }
      }
      let existing = match started_project {
        Some(project) =>
          {
            ..existing,
            workspace: dev.conversation_workspace(
              project,
              session,
              existing.workspace,
            ),
          }
        // A rootless legacy event asserts nothing: the run's own store is
        // authoritative for where the record lives, but an event that names
        // none must not move a placement the user chose. That reconcile
        // belongs to the session list.
        None => existing
      }
      // An automatically promoted follow-up is still transient until this
      // ordinary Started boundary. Retire its in-memory queue row here; the
      // corresponding User commit is the first durable representation of it.
      let existing = if submission_id is Some(id) &&
        existing.queued_inputs.any(item => item.id == id) {
        let (without_queue, _) = existing.remove_queued_input(id)
        {
          ..without_queue,
          pending_steers: without_queue.pending_steers.filter(input => {
            input.submission_id != id
          }),
        }
      } else {
        existing
      }
      let owned = submission_id is Some(id) &&
        existing.has_initial_submission(id)
      let current_start = submission_id is Some(id) &&
        existing.run is Starting(submission_id=current) &&
        current == id
      let same_open = existing.run is Open(run_id=current, ..) &&
        current == run_id
      let conv = existing
      let (conv, foreign, stale_terminal) = match conv.run {
        Starting(..) if owned && current_start => (conv, false, false)
        // A foreign run starting says nothing about this client's own start,
        // which is still in flight and still owns its receipt path — a late
        // rejection must remain able to restore that draft.
        Starting(..) => (conv, true, false)
        Open(run_id=current, ..) if current == run_id => (conv, false, false)
        Open(run_id=previous_run, ..) =>
          (
            conv.clear_streams().forget_steers_for_run(previous_run),
            true,
            false,
          )
        NoRun(..) if existing.last_run_id is Some(last) && last == run_id =>
          (conv, false, true)
        NoRun(..) => (conv, true, false)
      }
      // The prompt bubble is not appended at this lifecycle boundary. Durable
      // transcript snapshots and `session.event` commits are its only sources.
      // A foreign run means the store holds a lifecycle boundary this client
      // cannot infer from item kinds: a delayed User may still belong to the
      // prior run as a steer. Re-read active and background conversations
      // alike; commits buffer until that snapshot establishes the new run's
      // terminal floor. If an older read is already in flight, mark one
      // follow-up generation: its pre-Started cut may drain commits, but may
      // not establish this run's floor.
      // Every newly observed Started boundary gets a post-Started snapshot,
      // including an owned local start. External/CLI turns may have advanced
      // the store while this page was idle without a follower broadcasting
      // them; reusing Send's stale terminal floor would let that older
      // terminal be mistaken for this run's. The host admits this Started
      // only after its predecessor's final drain, so this read is the first
      // safe place to establish the new floor.
      let refresh = foreign || current_start
      let run = if stale_terminal {
        conv.run
      } else {
        match conv.run {
          Open(run_id=current, stage~) if current == run_id =>
            Open(run_id=current, stage~)
          _ => Open(run_id~, stage=Opened)
        }
      }
      let sync = if refresh &&
        conv.sync
        is Reloading(generation~, attempt~, buffered~, reload_after_current=_) {
        Reloading(generation~, attempt~, buffered~, reload_after_current=true)
      } else {
        conv.sync
      }
      // A Started that opens a different run starts its turn from nothing:
      // the fragment, sub-run lanes and token count the previous turn
      // accumulated belong to that turn, not this one. A repeat of the open
      // run's Started, or a late one for a run already settled, keeps what it
      // has.
      let turn : RunState = if stale_terminal || same_open {
        conv.turn
      } else {
        RunState::for_run(conv.durable_frontier())
      }
      // `foreign` is exactly the question the elapsed span needs answered: a
      // run this page did not submit and wait for has an age that started
      // before we were watching. Keeping the previous run's start would date
      // the new one from a moment it never had; the span is simply omitted
      // until a submit of ours establishes one.
      let run_started_ms = if foreign { None } else { conv.run_started_ms }
      let conv = {
        ..conv,
        run,
        turn,
        run_started_ms,
        sync,
        // The tier is deliberately NOT re-established from the run. A start
        // is always older than the composer: the user may have flipped the
        // chip for the next turn while this one was still being spawned, and
        // a turn another client started says nothing about what this user
        // intends to send. The chip means "what your next turn runs on", so
        // only the chip changes it.
        last_run_id: Some(run_id),
      }
      let (updated, generation) = if refresh {
        model.begin_transcript_reload(conv)
      } else {
        (model.replace_conversation(conv), None)
      }
      // Probe the root projected from the reconciled conversation.
      let (branch_cmd, updated) = probe_branch(
        dispatch,
        updated,
        channel,
        session,
        updated.conversation_root(conv),
      )
      let commands = [branch_cmd]
      if generation is Some(generation) {
        commands.push(
          session_snapshot_command(
            dispatch, channel, updated, session, generation, false,
          ),
        )
      }
      // A run is what makes a conversation durable, so this is where its tier
      // gets pinned — the chip is not the only way to acquire one. A tier
      // merely inherited from the page default and then used would otherwise
      // stay unremembered, and the conversation would come back on whatever
      // default an unrelated chat has moved to since. Re-pinning the same
      // tier only reorders the list, so consecutive turns write once.
      let pinned = updated.remember_model(channel, session, conv.engine_model)
      if pinned.conversation_models != model.conversation_models {
        commands.push(
          save_conversation_model(
            conversation_model_key(channel, session),
            conv.engine_model,
          ),
        )
      }
      let updated = pinned
      // The model rode in on the conversation above; max steps is still one
      // global setting, so sync it only when this start belongs to the
      // conversation on screen. A slow background start (the user switched
      // chats mid-spawn) must not overwrite a value the user has since
      // changed for the now-active conversation.
      if channel == updated.focused && session == updated.active_session {
        (@cmd.batch(commands), { ..updated, max_steps: max_steps.to_string(), })
      } else {
        (@cmd.batch(commands), updated)
      }
    }
    RunsLoaded(
      runs~,
      settled~,
      approvals~,
      live~,
      frontier~,
      connection_generation~
    ) => {
      guard connection_generation == dev.connection_generation else {
        return (@cmd.none, model)
      }
      // Accept the snapshot as one state transition. No intermediate replayed
      // Started row is rendered, and a later BridgeReady invalidates both its
      // positive rows and its negative frontier together.
      let commands : Array[@cmd.Cmd] = []
      let mut next = model
      let accepted_settlements : Array[RecoveredSettlement] = []
      let settled_sessions : Array[String] = []
      for settlement in settled {
        if !accepted_settlements.any(item => item.run_id == settlement.run_id) &&
          model.matched_settlement_frontier(channel, frontier, settlement)
          is Some(_) {
          accepted_settlements.push(settlement)
          if !settled_sessions.contains(settlement.session) {
            settled_sessions.push(settlement.session)
          }
        }
      }
      // Validate positive rows against the same immutable request-time model,
      // before a predecessor settlement mutates it. One atomic host snapshot
      // may legitimately contain completed r1 and active successor r2 for the
      // same session; both pieces must survive that hand-off.
      let accepted_runs : Array[RecoveredRun] = []
      let admitted_run_sessions : Array[String] = []
      for run in runs {
        let duplicates_settlement = accepted_settlements.any(item => {
          item.session == run.session && item.run_id == run.run_id
        })
        if !duplicates_settlement &&
          !admitted_run_sessions.contains(run.session) &&
          model.matches_run_snapshot_frontier(channel, frontier, run.session) {
          accepted_runs.push(run)
          admitted_run_sessions.push(run.session)
        }
      }
      // A completion selected by this request is stronger than mere absence.
      // Replay it before active rows and negative settlement, but only while
      // the page still has the exact owner captured at request time. A
      // Starting owner first gains the host run id so the ordinary Finished
      // transition can retire or restore its exact initial submission.
      // A session can carry an older run selector and a newer unbound prompt
      // selector at the same cut. Apply run-owned evidence first, then the
      // submission-owned completion that controls the current composer gate.
      let ordered_settlements : Array[RecoveredSettlement] = []
      for settlement in accepted_settlements {
        if model.matched_settlement_frontier(channel, frontier, settlement)
          is Some(SettlementByRun) {
          ordered_settlements.push(settlement)
        }
      }
      for settlement in accepted_settlements {
        if model.matched_settlement_frontier(channel, frontier, settlement)
          is Some(SettlementBySubmission(_)) {
          ordered_settlements.push(settlement)
        }
      }
      for settlement in ordered_settlements {
        guard model.matched_settlement_frontier(channel, frontier, settlement)
          is Some(owner) else {
          continue
        }
        if owner is SettlementBySubmission(submission_id) &&
          next.find_conversation(channel, settlement.session) is Some(conv) {
          // The settlement names the run this submission opened, so the
          // prompt in flight finally has its answer.
          let (settled, _) = conv.settle_pending_prompt(submission_id)
          next = next.replace_conversation({
            ..settled,
            run: Open(run_id=settlement.run_id, stage=Opened),
            turn: RunState::empty(),
            last_run_id: Some(settlement.run_id),
          })
        }
        let (cmd, updated) = update_device_msg(
          dispatch,
          channel,
          Finished(
            run_id=settlement.run_id,
            status=settlement.status,
            answer=None,
          ),
          next,
        )
        commands.push(cmd)
        next = updated
      }
      for run in accepted_runs {
        let (cmd, updated) = update_device_msg(
          dispatch,
          channel,
          Started(
            run_id=run.run_id,
            session=run.session,
            model=run.model,
            max_steps=run.max_steps,
            session_root=run.session_root,
            submission_id=run.submission_id,
          ),
          next,
        )
        commands.push(cmd)
        next = updated
      }
      // Do not let the older negative-set logic re-anchor a completion that
      // just supplied an exact durable frontier (notably sequence zero).
      let unsettled_frontier = frontier.filter(captured => {
        !settled_sessions.contains(captured.session)
      })
      let (settled_cmd, settled) = update_device_msg(
        dispatch,
        channel,
        RunsSettled(live~, frontier=unsettled_frontier),
        next,
      )
      commands.push(settled_cmd)
      // Standing questions land last, once every conversation in this snapshot
      // has the run phase the snapshot gives it.
      //
      // Two passes, because they answer two different questions of two
      // different sets. Seeding asks what the reply says exists, so it iterates
      // the REPLY — a fresh page captures an empty frontier (`BridgeReady`
      // issues this alongside `session.list`, before any conversation exists),
      // and iterating the frontier would drop every question on the one path
      // the replay was built for. Retiring asks what this page was showing that
      // the reply lacks, which only the frontier knows.
      let captured_by_session : Map[String, RunSnapshotFrontier] = Map([])
      for row in frontier {
        captured_by_session[row.session] = row
      }
      let mut seeded = settled
      for recovered in approvals {
        guard seeded.find_conversation(channel, recovered.session) is Some(conv) else {
          continue
        }
        let showing = conv.pending_approval.map(pending => pending.id)
        // Unchanged since the request went out — a session absent from the
        // frontier captured nothing, so it must be showing nothing now.
        // Anything else is newer truth than the reply, live events having
        // landed meanwhile.
        let captured = match captured_by_session.get(recovered.session) {
          Some(row) => row.pending_approval_id
          None => None
        }
        guard showing == captured else { continue }
        // And the question must belong to the run this conversation has open.
        // The check above compares two endpoints, so it cannot see a value
        // that changed and changed back: with nothing captured, one question
        // asked and resolved in flight, and its run replaced by a successor,
        // both endpoints read `None` and this dead question would be seeded
        // onto the new run — where answering it is rejected and the failure
        // handler puts the buttons back, leaving a prompt that can never be
        // dismissed. A question only exists inside a turn, so a conversation
        // with no open run has none to restore.
        guard conv.run is Open(run_id~, ..) &&
          recovered.approval.run_id is Some(approval_run_id) &&
          approval_run_id == run_id else {
          continue
        }
        // Already on screen unchanged: leave it, answered flag and all. This
        // resync runs on every reconnect, not only after a reload, so handing
        // the buttons back to a card the user has already answered would be
        // one question with two decisions.
        if showing is Some(id) && id == recovered.approval.id {
          continue
        }
        seeded = seeded.replace_conversation({
          ..conv,
          pending_approval: Some(recovered.approval),
        })
      }
      // Retire: a question this page was showing that the reply lacks was
      // answered while the page was away — by another client, or by the run
      // ending. Its `approval_resolved` is gone for good (reconnect is resync;
      // transients are not replayed), so nothing else will ever take that card
      // down, and pressing it sends a decision the engine's desk discards.
      //
      for captured in frontier {
        guard captured.pending_approval_id is Some(captured_id) else {
          continue
        }
        if approvals.any(item => item.approval.id == captured_id) {
          continue
        }
        guard seeded.find_conversation(channel, captured.session) is Some(conv) else {
          continue
        }
        if conv.pending_approval is Some(current) && current.id == captured_id {
          seeded = seeded.replace_conversation({
            ..conv,
            pending_approval: None,
          })
        }
      }
      (@cmd.batch(commands), seeded)
    }
    RunsSettled(live~, frontier~) => {
      // A conversation still showing an open run the host no longer has: the
      // run ended while this client was away, and its terminal event will
      // never be replayed, so the phase settles here. How it ended is
      // unknowable (`ended=None`); the verdict text lives in the store and
      // arrives through the usual reads — the active conversation reloads at
      // `BridgeReady`, the rest when opened. Only a lifecycle state that still
      // exactly matches this request's per-session frontier may settle; live
      // Started/Finished transitions received meanwhile are newer truth.
      let settled = model.conversations.map(conv => {
        if conv.device != channel {
          return conv
        }
        for captured in frontier {
          if captured.session == conv.session_id {
            return match captured.state {
              SnapshotOpen(run_id~) if conv.run is Open(run_id=current, ..) &&
                current == run_id &&
                !live.contains(run_id) =>
                // The runs reply proves this run is over. Its submissions can
                // no longer acquire a receipt, so they end with it; the
                // transcript, not a local notice, says what the run recorded.
                {
                  ..conv.clear_streams().forget_steers_for_run(run_id),
                  run: NoRun(ended=None),
                  last_run_id: Some(run_id),
                }
              SnapshotIdle(last_run_id=Some(run_id)) if conv.run is NoRun(..) &&
                conv.last_run_id is Some(current) &&
                current == run_id =>
                // The run this conversation last owned is idle at the host,
                // so nothing it carried is still in flight.
                conv.forget_steers_for_run(run_id)
              SnapshotStarting(submission_id~) if conv.run
                is Starting(submission_id=current) &&
                current == submission_id => {
                // The host has no record of this start, so the prompt never
                // opened a run. Close the local lifecycle and let the entry
                // go with it.
                let (settled, _) = conv.settle_pending_prompt(submission_id)
                { ..settled.clear_streams(), run: NoRun(ended=None), }
              }
              _ => conv
            }
          }
        }
        conv
      })
      (@cmd.none, { ..model, conversations: settled, })
    }
    JobsChanged(session) =>
      if model.jobs.owner is Some(owner) &&
        owner.channel == channel &&
        owner.scope.session == session {
        let (cmd, jobs) = @jobs.update(
          locale=model.locale,
          dispatch.map(msg => Jobs(msg)),
          Poll,
          model.jobs,
        )
        (cmd, { ..model, jobs, })
      } else {
        (@cmd.none, model)
      }
    Engine(run_id, event, session~) => {
      // Compaction and background notices happen between turns, so their
      // events arrive after the run that owned `run_id` cleared
      // `active_run_id` — or with no run id at all (an engine spawned just
      // to compact). The host stamps them with their session, which covers
      // that case too; the conversation that last held the id remains the
      // fallback for unstamped events.
      let conv = if run_id is Some(id) &&
        model.conversation_by_run(channel, id) is Some(conv) {
        Some(conv)
      } else if is_steer_receipt(event) && run_id is Some(id) {
        // Host settling receipts may intentionally trail the terminal event;
        // an even newer Started can already have replaced last_run_id. Prefer
        // the exact pending-steer match before the legacy run fallback.
        let exact = match event {
          SteerApplied(submission_id=Some(submission_id), ..) =>
            model.conversation_by_pending_steer(channel, submission_id, id)
          SteerDropped(submission_id=Some(submission_id), ..) =>
            model.conversation_by_pending_steer(channel, submission_id, id)
          _ => None
        }
        if exact is Some(conv) {
          Some(conv)
        } else {
          model.conversation_by_last_run(channel, id)
        }
      } else if is_idle_event(event) {
        if session is Some(session) &&
          model.find_conversation(channel, session) is Some(conv) {
          Some(conv)
        } else if run_id is Some(id) {
          model.conversation_by_last_run(channel, id)
        } else {
          None
        }
      } else {
        None
      }
      if conv is Some(conv) {
        let approval_notification = approval_system_notification(
          channel, run_id, event,
        )
        let (report, next) = apply_engine_event(conv, event, run_id)
        let updated = model.replace_conversation(next)
        // The finish is a sub-run child's terminal refresh boundary, and the
        // only one it has. The host cancels the progress probe here without a
        // final poll, and the probe sleeps before it reads — so everything the
        // child wrote since the last tick, which is where its report lands,
        // reaches a reader watching that transcript through this event or not
        // at all.
        let (finished_cmd, updated) = if event is SubrunClosed(id~, ..) {
          refresh_visible_subrun_child(
            dispatch,
            channel,
            "\{conv.session_id}-\{id}",
            updated,
          )
        } else {
          (@cmd.none, updated)
        }
        let (report_cmd, updated) = if report is Some(text) {
          updated.notify_error(dispatch, text)
        } else {
          let command = match approval_notification {
            Some(notification) => notification.command(locale=updated.locale)
            None => @cmd.none
          }
          (command, updated)
        }
        (@cmd.batch([finished_cmd, report_cmd]), updated)
      } else {
        (@cmd.none, model)
      }
    }
    // Everything else the panel owns (tree, viewer, diagnostics) is the
    // fileeditor package's business; route it there and adopt its state.
    StartResponded(session~, submission_id~, run_id~, status~, exit_code~) => {
      guard model.find_conversation(channel, session) is Some(conv) &&
        conv.has_initial_submission(submission_id) else {
        return (@cmd.none, model)
      }
      // The id-bearing reply always settles its exact submission, even when
      // Finished A and Started B overtook A's RPC response. Only lifecycle
      // mutation remains conditional on A still owning the conversation.
      let owns_lifecycle = match conv.run {
        Starting(submission_id=current) => current == submission_id
        Open(run_id=current, ..) => current == run_id
        NoRun(..) => conv.last_run_id is Some(last) && last == run_id
      }
      // A prompt is sent once. Whatever the host answered, this submission's
      // entry has served its purpose — it existed to recognize this reply —
      // and nothing downstream reconciles it against the record.
      let (conv, _) = conv.settle_pending_prompt(submission_id)
      if status == "accepted" {
        let missed_started = owns_lifecycle &&
          conv.run is Starting(submission_id=current) &&
          current == submission_id
        let late_abnormal = conv.run is NoRun(..) &&
          conv.last_run_id is Some(owner) &&
          owner == run_id &&
          !(conv.run is NoRun(ended=Some(RunFinished(outcome))) &&
          outcome is (Completed | ContextYield | MaxStepsExhausted))
        let settled = conv
        // The reply still opens the lifecycle when its Started notification
        // was delayed. A very short run may already be finished; never
        // resurrect that settled phase.
        let next = if owns_lifecycle {
          match settled.run {
            NoRun(..) => settled
            Open(run_id=current, stage~) if current == run_id =>
              {
                ..settled,
                run: Open(run_id=current, stage~),
                last_run_id: Some(run_id),
              }
            // This page submitted and is now being told the run it was
            // waiting for opened: the submit is still where the user's wait
            // began, so the span carries over.
            Starting(..) =>
              {
                ..settled,
                run: Open(run_id~, stage=Opened),
                last_run_id: Some(run_id),
              }
            // Some other run opened — reconnect adopting one already in
            // flight, or a turn started elsewhere. Its age is not this page's
            // to know, and the previous run's start would be a lie.
            _ =>
              {
                ..settled,
                run: Open(run_id~, stage=Opened),
                last_run_id: Some(run_id),
                run_started_ms: None,
              }
          }
        } else {
          settled
        }
        let (updated, generation) = if missed_started || late_abnormal {
          model.ensure_transcript_reload_after_current(next)
        } else {
          (model.replace_conversation(next), None)
        }
        let (branch_cmd, updated) = probe_branch(
          dispatch,
          updated,
          channel,
          session,
          updated.conversation_root(settled),
        )
        let commands = [branch_cmd]
        if generation is Some(generation) {
          commands.push(
            session_snapshot_command(
              dispatch, channel, updated, session, generation, false,
            ),
          )
        }
        (@cmd.batch(commands), updated)
      } else {
        // The process result closes a still-live run. Whether its User append
        // reached the store is the record's question, not this reply's, and
        // the reload below is what answers it.
        ignore(status)
        ignore(exit_code)
        let closed = if owns_lifecycle {
          conv.forget_steers_for_run(run_id)
        } else {
          conv
        }
        let next = if owns_lifecycle {
          match closed.run {
            Starting(..) | Open(..) =>
              {
                ..closed.clear_streams(),
                run: NoRun(ended=Some(RunFailed)),
                last_run_id: Some(run_id),
              }
            NoRun(..) => closed
          }
        } else {
          closed
        }
        let (model, generation) = model.ensure_transcript_reload_after_current(
          next,
        )
        let (sessions, model) = request_sessions_refresh(
          dispatch, channel, model,
        )
        let commands = [
          sessions,
          fetch_runs(
            dispatch,
            channel,
            model.run_snapshot_frontier(channel),
            dev.connection_generation,
          ),
        ]
        if generation is Some(generation) {
          commands.push(
            session_snapshot_command(
              dispatch, channel, model, session, generation, false,
            ),
          )
        }
        (@cmd.batch(commands), model)
      }
    }
    StartUndelivered(session~, submission_id~, message~) =>
      if model.find_conversation(channel, session) is Some(conv) {
        // The response path failed, so whether the host took this prompt is
        // unknowable here. Nothing guesses on the client's behalf: the entry
        // ends and the reload below shows what the record actually holds.
        ignore(message)
        let owns_submission = conv.has_initial_submission(submission_id)
        let (settled, changed) = conv.settle_pending_prompt(submission_id)
        if !owns_submission {
          (@cmd.none, model)
        } else {
          let next = if conv.run is Starting(submission_id=current) &&
            current == submission_id {
            { ..settled.clear_streams(), run: NoRun(ended=Some(RunFailed)), }
          } else {
            // A Started push/response for another run won the race. An
            // uncorrelated transport failure must never close that open run.
            settled
          }
          let updated = model.replace_conversation(next)
          let (sessions, updated) = request_sessions_refresh(
            dispatch, channel, updated,
          )
          let commands = [
            sessions,
            fetch_runs(
              dispatch,
              channel,
              updated.run_snapshot_frontier(channel),
              dev.connection_generation,
            ),
          ]
          if changed {
            commands.push(@cmd.none)
          }
          (@cmd.batch(commands), updated)
        }
      } else {
        (@cmd.none, model)
      }
    StartRejected(session~, submission_id~, message~) =>
      model.reject_start(dispatch, channel, session, submission_id, message)
    WorktreeSetupFailed(session~, submission_id~, message~) =>
      model.reject_start(dispatch, channel, session, submission_id, message)
    Error(run_id~, message~, diagnostics~, exit_code~) => {
      // Agent-side semantic errors are lifecycle-only here; their durable
      // status is classified by the subsequent Finished event. Process
      // diagnostics carry `exit_code` and have no durable twin.
      let conv = if run_id is Some(run_id) {
        if model.conversation_by_run(channel, run_id) is Some(conv) {
          Some(conv)
        } else {
          model.conversation_by_last_run(channel, run_id)
        }
      } else if channel == model.focused {
        model.active_conversation()
      } else {
        None
      }
      if conv is Some(conv) {
        if run_id is Some(_) && exit_code is None {
          return (@cmd.none, model)
        }
        let content = if diagnostics is Some(diagnostics) &&
          !diagnostics.is_blank() {
          "\{message}\n\n\{diagnostics}"
        } else {
          message
        }
        // Neither kind belongs to a durable event: the record will never
        // carry either, and the transcript is where durable events go. Both
        // are reported as toasts, and the top bar's `Errored` status is what
        // stands once the toast dismisses itself.
        let settled = model.replace_conversation(
          if conv.run is NoRun(..) {
            { ..conv, run: NoRun(ended=Some(RunErrored)), }
          } else {
            conv
          },
        )
        settled.notify_error(dispatch, content)
      } else {
        (@cmd.none, model)
      }
    }
    CompactRejected(session~, message~) =>
      if model.find_conversation(channel, session) is Some(conv) {
        model
        .replace_conversation({ ..conv, compaction: NotCompacting, })
        .notify_error(dispatch, message)
      } else {
        (@cmd.none, model)
      }
    GoalRejected(session~, command~, draft~, message~) =>
      if model.find_conversation(channel, session) is Some(conv) {
        // A rejection acts only on the send it answers, and only while that
        // send is still the one in flight. The row keeps its actions while a
        // command is out, so the user can send a second over the first — and
        // the second may be the same text, or Clear again, so only the id
        // separates them.
        //
        // Anything else is a reply that arrived too late to mean what it
        // says. Either a newer send replaced this one, or the record already
        // settled whatever was outstanding — including by carrying this very
        // text, set from somewhere else. In every such case the durable goal
        // has already been decided, so retiring the slot would drop a live
        // successor and reopening the editor would claim a failure that is
        // not what this conversation now stands at. The toast still reports
        // it; nothing here is silent.
        let restored = if !(conv.goal_pending is Some(pending) &&
          pending.id == command) {
          conv
        } else if draft is Some(draft) && conv.goal_edit is None {
          // Hand the goal text back, the way a rejected prompt restores its
          // draft: nothing durable will ever carry it, so losing it here
          // loses it for good. Only when this conversation has not claimed
          // goal mode since — a newer edit is the user's, not this dead
          // request's.
          { ..conv, goal_edit: Some({ draft, }), goal_pending: None, }
        } else {
          { ..conv, goal_pending: None, }
        }
        model.replace_conversation(restored).notify_error(dispatch, message)
      } else {
        (@cmd.none, model)
      }
    GoalUndelivered(session~, command~, draft~, message~) =>
      if model.find_conversation(channel, session) is Some(conv) &&
        conv.goal_pending is Some(pending) &&
        pending.id == command {
        // Only while this send is still the one in flight. It retires
        // nothing, but "the fate of this text is unknown" is still a claim
        // about the world, and it stops being true the moment the record
        // settles the send — the socket can die after the commit arrives and
        // before the reply does — or a newer send replaces it.
        //
        // While it is true, the request stays in flight: a marker, or the
        // reload that follows the reconnect, is what settles it. So the text
        // cannot come back to the editor — it would claim the goal is unset,
        // and a resend over a command the host may already hold only earns a
        // refusal. Nothing is lost by leaving it there: the request in flight
        // still carries it, and that is what the goal row shows and what
        // reopening the editor seeds from.
        ignore(draft)
        let detail = if conv.goal_pending is Some({ request: Clearing, .. }) {
          " — check the goal row before clearing it again"
        } else {
          " — check the goal row before setting it again"
        }
        model
        .replace_conversation(conv)
        .notify_error(
          dispatch,
          (match model.locale {
            SimplifiedChinese => "无法确认目标是否已送达（"
            TraditionalChinese => "無法確認目標是否已送達（"
            Japanese => "目標が届いたか確認できません（"
            English => "Goal delivery could not be confirmed ("
            Spanish => "No se pudo confirmar la entrega del objetivo ("
          }) +
          message +
          ")" +
          detail,
        )
      } else {
        (@cmd.none, model)
      }
    Finished(run_id~, status~, answer~) =>
      if (if model.conversation_by_run(channel, run_id) is Some(conv) {
          Some(conv)
        } else {
          // RunsSettled may have closed the phase first; Finished is still the
          // authoritative outcome for the conversation that last owned it.
          model.conversation_by_last_run(channel, run_id)
        })
        is Some(conv) {
        let first_finish = !(conv.run is NoRun(ended=Some(RunFinished(_))) &&
          conv.last_run_id is Some(last) &&
          last == run_id)
        // Missing receipts are not guessed dropped. Keep exact-id ownership
        // briefly and show a truthful unconfirmed notice behind the durable
        // terminal boundary; a trailing receipt may still settle it.
        //
        // The run is over, so nothing it carried can still acquire a receipt.
        // Whether each submission reached the store is the record's question;
        // the transcript answers it without a local placeholder.
        let outcome = RunOutcome::parse(status)
        let settled_inputs = conv.clear_streams().forget_steers_for_run(run_id)
        // A dead/aborted serve process loses its controller-owned queue. A
        // normal terminal keeps it for the Started boundary that immediately
        // promotes the next ordinary prompt.
        let settled_inputs = match outcome {
          Aborted | RunFailed | Unknown(_) =>
            {
              ..settled_inputs,
              queued_inputs: [],
              queue_edit_id: None,
              pending_steers: settled_inputs.pending_steers.filter(input => {
                input.behavior is FollowupSteer
              }),
            }
          Completed | ContextYield | MaxStepsExhausted => settled_inputs
        }
        // A question belonging to this run goes with it. The engine settles
        // its own on the way out, so what reaches here is the engine that
        // could not — a killed process emits no `approval_resolved` — and
        // nothing else would ever retire the card, there being no deadline
        // behind the question. The host drops its copy on the same evidence.
        let settled_inputs = if settled_inputs.pending_approval
          is Some({ run_id: Some(owner), .. }) &&
          owner == run_id {
          { ..settled_inputs, pending_approval: None, }
        } else {
          settled_inputs
        }
        let base = {
          ..settled_inputs,
          run: NoRun(ended=Some(RunFinished(outcome))),
          last_run_id: Some(run_id),
          // A finish the user watched happen needs no reminder. Every other
          // completion is unread until its transcript is actually visible.
          unseen_finish: !model.conversation_is_visible(
            conv.device,
            conv.session_id,
          ),
        }
        // The finished run just appended to the durable store, so the
        // sidebar list (and this conversation's title) may have changed —
        // and the turn may have created the repository or switched branches.
        let mut next = model.replace_conversation(base)
        let (sessions, requested) = request_sessions_refresh(
          dispatch, channel, next,
        )
        next = requested
        let (branch_cmd, probed) = probe_branch(
          dispatch,
          next,
          channel,
          conv.session_id,
          next.conversation_root(conv),
        )
        next = probed
        let commands = [sessions, branch_cmd]
        // Only the embedded desktop page owns system notifications. Remote
        // browser pages never have the notification extension, and replaying
        // the same Finished boundary must not post a second notification.
        if first_finish && channel is Local {
          commands.push(
            FinishedSystemNotification::{ run_id, status, answer, }.command(
              locale=next.locale,
            ),
          )
        }
        // The turn's edits routinely land in files the editor panel never
        // shows — paths its pruned watcher does not cover — so the settled
        // boundary re-checks the active MoonBit file's module. The panel's
        // owner fence drops a finish from a conversation it is not showing.
        if first_finish {
          let (panel_cmd, panel_next) = update_msg(
            dispatch,
            FileEditor(RunSettled(owner={ channel, session: conv.session_id, })),
            next,
          )
          commands.push(panel_cmd)
          next = panel_next
        }
        // A run that recorded nothing needs this pass as much as any other:
        // the read answers "this conversation is empty" rather than failing,
        // so the reconciliation ends in Synced either way.
        if first_finish && !base.session_id.is_empty() {
          match base.sync {
            Reloading(generation~, attempt~, buffered~, reload_after_current~) =>
              // The current snapshot may have been captured before this
              // Finished boundary. Do not start a concurrent read; remember
              // to run exactly one fresh generation after it settles.
              if !reload_after_current {
                next = next.replace_conversation({
                  ..base,
                  sync: Reloading(
                    generation~,
                    attempt~,
                    buffered~,
                    reload_after_current=true,
                  ),
                })
              }
            Synced | ReloadFailed(..) => {
              let (reloading, generation) = next.begin_transcript_reload(base)
              next = reloading
              if generation is Some(generation) {
                commands.push(
                  session_snapshot_command(
                    dispatch,
                    channel,
                    next,
                    base.session_id,
                    generation,
                    false,
                  ),
                )
              }
            }
          }
        }
        (@cmd.batch(commands), next)
      } else {
        // Even when this page missed both Started and every commit, the list
        // can reveal the finished durable session for a later open.
        request_sessions_refresh(dispatch, channel, model)
      }
  }
}

// Purity and state-transition tests for the update handlers that back the
// streaming, session, and multi-conversation integration. Commands are
// opaque, so the tests assert on the returned model only.

///|
priv struct PendingReviewContext {
  owner : @interop.ConversationKey
  navigation : Int32
  selection : @mention_context.ReviewChanges
} derive(Eq)

///|
fn PendingReviewContext::is_current(
  self : PendingReviewContext,
  model : Model,
) -> Bool {
  let ctx = file_ctx(model)
  self.owner == ctx.owner &&
  self.navigation == model.file_panel.file_link_generation &&
  ctx.placement
  .bind(placement => placement.checkout_root())
  .map(root => root.path) ==
  Some(self.selection.source.workspace)
}

///|
fn open_review_context(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  selection : @mention_context.ReviewChanges,
) -> (@cmd.Cmd, Model) {
  let ctx = file_ctx(model)
  guard ctx.placement
    .bind(placement => placement.checkout_root())
    .map(root => root.path) ==
    Some(selection.source.workspace) else {
    return model.notify_error(
      dispatch, "This selection belongs to a review that is no longer available. Its saved context is unchanged.",
    )
  }
  if model.file_panel.changes
    is @fileeditor.ChangeListReady(refreshing=false, ..) {
    return open_loaded_review_context(dispatch, model, selection)
  }
  // Opening Changes starts (or joins) its normal owner/generation-fenced
  // inventory load. Keep the target separately until the authoritative reply
  // arrives; the viewer's reveal state requires an already-open document.
  let (command, opened) = open_explorer(dispatch, model, ExplorerChanges)
  (
    command,
    {
      ..opened,
      pending_review_context: Some({
        owner: ctx.owner,
        navigation: opened.file_panel.file_link_generation,
        selection,
      }),
    },
  )
}

///|
fn finish_review_context_load(
  dispatch : @cmd.Emit[Msg],
  msg : @fileeditor.Msg,
  before : @fileeditor.State,
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.pending_review_context is Some(pending) &&
    pending.is_current(model) else {
    return (@cmd.none, model)
  }
  let (owner, generation, error) = match msg {
    ChangesLoaded(owner~, generation~, ..) => (owner, generation, None)
    ChangesFailed(owner~, generation~, message~) =>
      (owner, generation, Some(message))
    _ => return (@cmd.none, model)
  }
  // A coalesced refresh is still loading. Stale/duplicate replies cannot
  // complete a newer jump, and an intermediate empty list is not deletion.
  guard before.owner == Some(owner) &&
    pending.owner == owner &&
    before.changes_generation == generation &&
    model.file_panel.changes_generation == generation &&
    before.changes
    is (ChangeListLoading(_) | ChangeListReady(refreshing=true, ..)) else {
    return (@cmd.none, model)
  }
  let model = { ..model, pending_review_context: None, }
  if error is Some(message) {
    return model.notify_error(
      dispatch,
      "Unable to load the current review: \{message}",
    )
  }
  open_loaded_review_context(dispatch, model, pending.selection)
}

///|
fn open_loaded_review_context(
  dispatch : @cmd.Emit[Msg],
  model : Model,
  selection : @mention_context.ReviewChanges,
) -> (@cmd.Cmd, Model) {
  guard model.file_panel.changes
    is @fileeditor.ChangeListReady(files~, refreshing=false, ..) &&
    files.search_by(change => {
      change.path.0 == selection.source.file &&
      change.original_path.map(path => path.0) == selection.source.original_file
    })
    is Some(index) else {
    return model.notify_error(
      dispatch, "This selection belongs to a review that is no longer available. Its saved context is unchanged.",
    )
  }
  let (command, opened) = update_msg(
    dispatch,
    FileEditor(@fileeditor.ChangedFileSelected(files[index])),
    model,
  )
  (
    command,
    {
      ..opened,
      right_panel_open: true,
      file_panel: opened.file_panel.with_review_context_reveal(selection),
    },
  )
}
