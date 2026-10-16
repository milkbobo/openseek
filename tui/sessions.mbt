///|
fn State::install_sessions(
  self : State,
  reply : @protocol.SessionsReply,
  archived : Bool,
) -> Unit {
  let keys : Array[ChatKey] = []
  if !archived && !self.active.key.archived {
    keys.push(self.active.key)
  }
  for group in reply.groups {
    if !group.error.is_empty() {
      self.notice = "\{group.name}: \{group.error}"
    }
    for entry in group.sessions {
      let key : ChatKey = {
        session: entry.id,
        workspace: Some(group.workspace),
        archived,
      }
      let chat = self.chats
        .get(key)
        .unwrap_or_else(() => {
          let chat = Chat(key, title=entry.title.unwrap_or(entry.id))
          self.chats[key] = chat
          chat
        })
      chat.session_root = Some(group.session_root)
      chat.title = entry.title.unwrap_or(entry.id)
      if !keys.contains(key) {
        keys.push(key)
      }
    }
  }
  for thread in self.codex.threads() {
    if self.chats
      .values()
      .find_first(chat => chat.codex_id() == Some(thread.id))
      is Some(chat) &&
      !keys.contains(chat.key) {
      keys.push(chat.key)
    }
  }
  self.sidebar = keys
  self.sidebar_index = self.sidebar.search(self.active.key).unwrap_or(0)
}

///|
async fn State::refresh_sessions(
  self : State,
  client : @client.Client,
  archived~ : Bool = false,
) -> Unit {
  let reply = if archived {
    client.call(@commands.session_list_archived, @protocol.NoPayload)
  } else {
    client.call(@commands.session_list, @protocol.NoPayload)
  }
  self.install_sessions(reply, archived)
}

///|
async fn State::load_chat(
  self : State,
  client : @client.Client,
  chat : Chat,
) -> Unit {
  self.active = chat
  self.workspace.clear()
  self.reveal_sidebar_chat(chat.key)
  self.pages.close()
  self.panel_title = None
  self.terminal_visible = false
  self.focus = Composer
  if chat.codex_id() is Some(id) {
    self.install_codex(self.codex.read(client, id), select=true)
    self.refresh_selected_workspace(client)
    return
  }
  self.load_snapshot(client, chat)
  self.refresh_selected_workspace(client)
  self.notice = chat.key.session
}

///|
async fn State::load_snapshot(
  self : State,
  client : @client.Client,
  chat : Chat,
) -> Unit {
  ignore(self)
  if chat.loading {
    return
  }
  chat.loading = true
  chat.snapshot_generation += 1
  let generation = chat.snapshot_generation
  defer (if chat.snapshot_generation == generation { chat.loading = false })
  let payload : @protocol.LoadSessionPayload = {
    session: chat.key.session,
    workspace: chat.key.workspace,
  }
  let reply = if chat.key.archived {
    client.call(@commands.session_load_archived, payload)
  } else {
    client.call(@commands.session_load, payload)
  }
  if chat.snapshot_generation == generation {
    chat.snapshot(reply)
  }
}

///|
fn State::apply_settings(
  self : State,
  settings : @protocol.SettingsStatusPayload,
) -> Unit {
  if self.settings is Some(current) && current.revision > settings.revision {
    return
  }
  let provider_changed = self.settings
    .map(current => current.provider != settings.provider)
    .unwrap_or(true)
  let compatible = match settings.provider {
    "glm" => self.model.has_prefix("glm-")
    "deepseek" =>
      !self.model.has_prefix("glm-") && !self.model.has_prefix("kimi-")
    _ => true
  }
  if !self.model_explicit || (provider_changed && !compatible) {
    self.model = if settings.provider == "glm" {
      "glm-5.3"
    } else {
      "deepseek-flash"
    }
    self.model_explicit = false
  }
  self.queue_followup = settings.followup_behavior == "queue"
  self.settings = Some(settings)
}

///|
fn State::reconcile_runs(
  self : State,
  reply : @protocol.RunsReply,
  owners : Array[(Chat, Int32)],
) -> Unit {
  for (chat, generation) in owners {
    if chat.codex_id() is Some(_) || chat.lifecycle_generation != generation {
      continue
    }
    let owned_run = chat.run_id
    let pending_ids = chat.pending.keys().collect()
    let running = reply.runs
      .iter()
      .find_first(run => {
        run.session == chat.key.session &&
        (chat.session_root is None || run.session_root == chat.session_root)
      })
    if running is Some(run) {
      chat.run_id = Some(run.run_id)
      chat.session_root = run.session_root
      chat.status = "Working"
      if run.submission_id is Some(id) && chat.queued.get(id) is Some(text) {
        chat.queued.remove(id)
        chat.pending[id] = text
      }
    } else {
      chat.run_id = None
      chat.live_answer = ""
      chat.live_reasoning = ""
      if owned_run is Some(_) || !pending_ids.is_empty() {
        chat.status = "Ready"
      }
    }
    for settled in reply.settled {
      guard settled.session == chat.key.session &&
        (
          owned_run == Some(settled.run_id) ||
          settled.submission_id
          .map(id => pending_ids.contains(id))
          .unwrap_or(false)
        ) else {
        continue
      }
      if settled.submission_id is Some(id) {
        chat.pending.remove(id)
        chat.queued.remove(id)
      }
      if chat.run_id is None {
        chat.status = settled.status
      }
    }
    if running is None {
      chat.pending.clear()
      chat.steering_drafts.clear()
    }
  }
  if reply.approval_generation >= self.approval_generation {
    self.approvals = reply.approvals
    self.approval_generation = reply.approval_generation
  }
}

///|
fn State::bind_workspace(self : State, chat : Chat, workspace : String) -> Unit {
  let old = chat.key
  let key : ChatKey = { ..old, workspace: Some(workspace), }
  if key == old {
    return
  }
  self.chats.remove(old)
  chat.key = key
  self.chats[key] = chat
  self.sidebar = self.sidebar.map(candidate => {
    if candidate == old {
      key
    } else {
      candidate
    }
  })
}

///|
async fn State::prepare_workspace(
  self : State,
  client : @client.Client,
  chat : Chat,
  place~ : Bool = true,
) -> Unit {
  guard chat.key.workspace is Some(requested) else {
    fail("Choose a workspace with /workspace before sending a prompt")
  }
  let listing = client.call(@commands.fs_browse, @protocol.BrowseDirectoryPayload::{
    path: Some(requested),
  })
  let workspace = match listing {
    Listing(path~, ..) => path
    BrowseError(message) => fail(message)
    Drives(..) =>
      fail("Choose a directory inside a drive for this conversation")
  }
  let attached = client.call(@commands.workspace_add, @protocol.WorkspacePayload::{
    path: requested,
  })
  if attached is WorkspaceError(message) {
    fail(message)
  }
  let settings = client.call(@commands.workspace_settings_get, @protocol.WorkspaceSettingsGetPayload::{
    workspace,
  })
  self.bind_workspace(chat, settings.workspace)
  if place && settings.worktree_mode {
    let created = client.call(@commands.worktree_create, @protocol.WorktreeCreatePayload::{
      workspace: settings.workspace,
      session: Some(chat.key.session),
      codex_thread: None,
    })
    if created is WorktreeCreateError(message) {
      fail(message)
    }
  }
  if place && physical_equal(self.active, chat) {
    self.refresh_selected_workspace(client)
  }
}

///|
async fn State::resync(self : State, client : @client.Client) -> Unit {
  self.refresh_sessions(client, archived=self.active.key.archived)
  self.refresh_sidebar_projects(client)
  let owners = self.chats
    .values()
    .map(chat => (chat, chat.lifecycle_generation))
    .collect()
  let known : Array[@protocol.KnownRunPayload] = []
  for (chat, _) in owners {
    if chat.run_id is Some(run_id) {
      known.push({
        session: chat.key.session,
        run_id: Some(run_id),
        submission_id: None,
      })
    }
    for submission_id, _ in chat.pending {
      known.push({
        session: chat.key.session,
        run_id: None,
        submission_id: Some(submission_id),
      })
    }
  }
  let reply = client.call(@commands.agent_runs, @protocol.RunsPayload::{
    known: Some(known),
  })
  self.reconcile_runs(reply, owners)
  let settings = client.call(@commands.settings_get, @protocol.NoPayload)
  self.apply_settings(settings)
  let active = self.active
  if !self.codex.threads().is_empty() {
    let tracked = Set(
      self.chats.values().filter_map(chat => chat.codex_id()).collect(),
    )
    try {
      for archived in [false, true] {
        for thread in self.codex.list(client, archived~, only=tracked) {
          self.install_codex(thread)
        }
      }
      self.codex_catalog_error = None
    } catch {
      error if @async.is_being_cancelled() => raise error
      error => self.codex_catalog_error = Some(error.to_string())
    }
  }
  for chat in self.chats.values().collect() {
    if chat.codex_id() is Some(id) {
      self.install_codex(self.codex.read(client, id)) catch {
        error if @async.is_being_cancelled() => raise error
        error => {
          chat.run_id = None
          chat.status = "Codex unavailable"
          chat.notice(error.to_string(), error=true)
        }
      }
    } else if chat.session_root is Some(_) &&
      (
        physical_equal(chat, active) ||
        chat.needs_reload ||
        !chat.pending.is_empty()
      ) {
      self.load_snapshot(client, chat)
    }
  }
  if !self.codex.threads().is_empty() {
    self.codex.sync_requests(client) catch {
      error if @async.is_being_cancelled() => raise error
      error => self.notice = "Codex questions: " + error.to_string()
    }
  }
  if self.active.key.workspace is Some(_) {
    if !self.active.loaded && self.active.codex_id() is None {
      self.prepare_workspace(client, self.active, place=false)
    }
    self.refresh_selected_workspace(client)
  }
  self.notice = "Connected"
}

///|
fn State::context(self : State) -> @workbench.Context {
  {
    session: self.active.codex_id().unwrap_or(self.active.key.session),
    codex_thread: self.active.codex_id(),
    workspace: self.active.key.workspace,
    model: self.model,
    run_id: self.active.run_id,
    archived: self.active.key.archived,
  }
}

///|
async fn State::send_prompt(
  self : State,
  client : @client.Client,
  text : String,
) -> Unit {
  let chat = self.active
  guard !chat.key.archived else {
    fail("Unarchive this chat before sending a prompt")
  }
  if chat.codex_id() is Some(_) && self.codex_catalog_error is Some(error) {
    fail(
      "Cannot verify Codex archive state; reconnect before sending: " + error,
    )
  }
  let draft_before = chat.draft.text()
  let submitted_text = text
  if chat.codex_id() is None && !chat.loaded && chat.run_id is None {
    self.prepare_workspace(client, chat)
  }
  if chat.codex_id() is Some(id) &&
    chat.codex_place_pending &&
    chat.run_id is None &&
    chat.key.workspace is Some(workspace) {
    let settings = client.call(@commands.workspace_settings_get, { workspace, })
    if settings.worktree_mode {
      let created = client.call(@commands.worktree_create, {
        workspace: settings.workspace,
        session: None,
        codex_thread: Some(id),
      })
      if created is WorktreeCreateError(message) {
        fail(message)
      }
      if physical_equal(self.active, chat) {
        self.refresh_selected_workspace(client)
      }
    }
  }
  let (text, images) = chat.prepare_prompt(client, text)
  if chat.codex_id() is Some(id) {
    let thread = self.codex.send(
      client,
      id,
      text,
      model?=self.codex_model,
      effort?=self.codex_effort,
      images~,
    )
    self.install_codex(thread)
    if chat.draft.text() == draft_before {
      chat.draft.clear()
    }
    chat.attachments.clear()
    chat.codex_place_pending = false
    return
  }
  let submission = self.submission()
  let steering = chat.run_id is Some(_) && !self.queue_followup
  if chat.run_id is Some(run_id) {
    if self.queue_followup {
      // A consumed-message receipt may arrive before the direct RPC reply.
      chat.queued[submission] = text
      chat.queued_drafts[submission] = {
        run_id,
        text: submitted_text,
        attachments: chat.attachments.copy(),
      }
      let reply = client.call(@commands.agent_queue, @protocol.QueuePayload::{
        run_id,
        action: QueueAdd(id=submission, text~, images~),
      }) catch {
        @client.ClientError::Rpc(..) as error => {
          chat.queued.remove(submission)
          chat.queued_drafts.remove(submission)
          raise error
        }
        error => raise error
      }
      guard reply.accepted else {
        chat.queued.remove(submission)
        chat.queued_drafts.remove(submission)
        fail(
          "This turn no longer accepts queued messages; resubmit your prompt",
        )
      }
    } else {
      chat.pending[submission] = text
      chat.remember_steer(submission, run_id, submitted_text)
      let reply = client.call(@commands.agent_steer, @protocol.SteerPayload::{
        images,
        text,
        run_id: Some(run_id),
        submission_id: Some(submission),
      }) catch {
        @client.ClientError::Rpc(..) as error => {
          ignore(chat.reject_steer(submission, Some(run_id)))
          raise error
        }
        error => raise error
      }
      if !reply.steered {
        ignore(chat.reject_steer(submission, Some(run_id)))
        fail("This turn no longer accepts steering; resubmit your prompt")
      }
    }
  } else {
    chat.pending[submission] = text
    let reply = client.call(@commands.agent_start, @protocol.StartPayload::{
      images,
      task: text,
      submission_id: Some(submission),
      model: Some(self.model),
      thinking: Some(self.thinking),
      max_steps: self.max_steps,
      session: chat.key.session,
      workspace: chat.key.workspace,
    }) catch {
      @client.ClientError::Rpc(..) as error => {
        chat.pending.remove(submission)
        raise error
      }
      error => raise error
    }
    if chat.run_id is None && chat.pending.contains(submission) {
      chat.run_id = Some(reply.run_id)
      chat.status = "Working"
    }
    chat.loaded = true
    self.panel_title = None
    chat.scroll.to_bottom()
  }
  if !steering {
    if chat.draft.text() == draft_before {
      chat.draft.clear()
    }
    chat.attachments.clear()
  }
  self.queue_followup = self.settings
    .map(settings => settings.followup_behavior == "queue")
    .unwrap_or(false)
}

///|
async fn State::approve(
  self : State,
  client : @client.Client,
  id : String,
  allow : Bool,
) -> Unit {
  guard self.approvals
    .iter()
    .find_first(item => item.id == id && !item.answered)
    is Some(approval) else {
    fail("No pending approval with id \{id}; use /approvals")
  }
  let reply = client.call(@commands.agent_approval, @protocol.ApprovalPayload::{
    id,
    allow,
    run_id: approval.run_id,
  })
  self.notice = if reply.delivered {
    "Decision sent"
  } else {
    "Approval already settled"
  }
}
