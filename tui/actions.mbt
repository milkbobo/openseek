///|
fn command_parts(text : String) -> (String, String) {
  if text.split_once(" ") is Some((command, rest)) {
    (command.to_owned(), rest.trim().to_owned())
  } else {
    (text, "")
  }
}

///|
fn local_help() -> Array[String] {
  [
    "CHAT",
    "/new [workspace] · /sessions [archived] · /open <number or id> · /search <text>",
    "/workspace <path> · /rename <title> · /archive [force] · /unarchive · /delete [force]",
    "/model <name> · /thinking off|high|max · /steps <number> · /stop · /compact",
    "/goal <text> · /goal clear · /goal auto <text> · /fork <event sequence> · /export · /share",
    "/queue [on|off] · /queue edit <id> <text> · /queue remove <id> · /queue steer <id>",
    "/approvals · /approve <id> · /deny <id>",
    "/mode codex|openseek · /codex list|new|open <id> · /codex requests",
    "Codex: /thinking none|minimal|low|medium|high|xhigh (model-dependent)",
    "/attach <server path> · /upload <local path> · /attachments · /detach <number|all>",
    "FILES",
    "/edit <file> · /file <file> · /read <file> · /diff <file> open native editor tabs.",
    "File tabs: Ctrl+S save · Ctrl+D diff view · Ctrl+R explorer · Ctrl+E editor.",
    "TERMINAL",
    "/terminal [command] · !<command> · /terminal close",
    "Ctrl+T switches chat/terminal; Ctrl+Left/Right switches terminals; Alt+W closes one.",
    "KEYS",
    "Enter sends · Alt+Enter or Ctrl+J inserts newline · Tab accepts next-message suggestion",
    "Ctrl+N new · Ctrl+B sidebar · Ctrl+P commands · Ctrl+T terminal · Ctrl+Q quit",
    "PgUp/PgDn scroll · drag selects · release copies via OSC 52 · Esc returns to chat",
    "SERVER",
    "/connection shows this server and sharing instructions.",
    "",
    ..@workbench.help(),
  ]
}

///|
async fn State::execute(
  self : State,
  client : @client.Client,
  text : String,
) -> Unit {
  if text.has_prefix("!") {
    self.open_terminal(
      client,
      Some(text.view(start_offset=1).trim().to_owned()),
    )
    return
  }
  if !text.has_prefix("/") {
    self.send_prompt(client, text)
    return
  }
  let (command, rest) = command_parts(text)
  let chat = self.active
  if command == "/codex" {
    self.codex_command(client, rest)
    return
  }
  if command == "/mode" {
    if rest == "codex" {
      self.codex_command(client, "new")
    } else if rest == "openseek" {
      self.start_chat(client, chat.key.workspace)
    } else {
      fail("Usage: /mode codex|openseek")
    }
    return
  }
  if chat.codex_id() is Some(id) {
    let codex_action = match command {
      "/new" => Some("new")
      "/stop" => {
        self.codex.interrupt(client, id)
        return
      }
      "/compact" => Some("compact " + id)
      "/rename" => Some("rename " + id + " " + rest)
      "/archive" =>
        Some("archive " + id + (if rest == "force" { " --force" } else { "" }))
      "/unarchive" => Some("unarchive " + id)
      "/goal" | "/queue" | "/fork" | "/delete" =>
        fail(
          "This action is available for OpenSeek chats; use /codex for Codex actions",
        )
      _ => None
    }
    if codex_action is Some(action) {
      self.codex_command(client, action)
      return
    }
  }
  match command {
    "/skills" if rest.is_empty() => self.show_page(client, Some(@pages.Skills))
    "/settings" if rest.is_empty() =>
      self.show_page(client, Some(@pages.Settings))
    "/schedules" => self.show_page(client, Some(@pages.Schedules))
    "/schedule" if rest.is_empty() =>
      self.show_page(client, Some(@pages.Schedules))
    "/files" if rest.is_empty() => {
      self.pages.close()
      self.workspace.browse(client, self.context())
      self.workspace.focus_tree()
      self.right_visible = true
      self.focus = Workspace
    }
    "/file" | "/read" | "/diff" | "/edit" if !rest.is_empty() => {
      self.pages.close()
      self.workspace.open(
        client,
        self.context(),
        file_argument(rest),
        diff=command == "/diff",
      )
      self.editor_visible = true
      self.focus = Workspace
    }
    "/attach" => self.attach(client, rest)
    "/upload" => self.upload(client, rest)
    "/attachments" =>
      self.panel("Composer attachments", chat.attachments.labels())
    "/detach" => {
      if rest == "all" {
        chat.attachments.clear()
      } else {
        guard chat.attachments.remove(@string.parse_int(rest) - 1) else {
          fail("No attachment with that number; use /attachments")
        }
      }
      self.notice = "Attachment removed"
    }
    "/help" => self.panel("Commands", local_help())
    "/connection" =>
      self.panel("Shared server", [
        self.server_url,
        "The TUI and desktop use the same command, event, session, and PTY services.",
        "Connect another client with --connect URL --token TOKEN or --server-file FILE.",
        "Start a persistent host with just seekmoon-server --root desktop/dist/browser.",
      ])
    "/new" =>
      self.start_chat(
        client,
        if rest.is_empty() {
          chat.key.workspace
        } else {
          Some(file_argument(rest))
        },
      )
    "/workspace" => {
      guard !rest.is_empty() else {
        fail("Usage: /workspace <server directory>")
      }
      if rest.has_prefix("add ") || rest.has_prefix("remove ") {
        let output = @workbench.execute(client, text, self.context())
        self.panel(output.title, output.lines)
        self.refresh_sessions(client)
        return
      }
      let path = file_argument(rest)
      let reply = client.call(@commands.workspace_add, @protocol.WorkspacePayload::{
        path,
      })
      match reply {
        Workspaces(_, ..) => self.start_chat(client, Some(path))
        WorkspaceError(message) => fail(message)
      }
      self.notice = "Workspace attached"
      self.refresh_sessions(client)
    }
    "/sessions" => {
      self.refresh_sessions(client, archived=rest == "archived")
      self.focus = Sidebar
      self.sidebar_visible = true
    }
    "/open" => {
      let number = @string.parse_int(rest) catch { _ => -1 }
      let chat = if number > 0 {
        self.sidebar.get(number - 1).bind(key => self.chats.get(key))
      } else {
        self.unique_session(rest)
      }
      guard chat is Some(chat) else {
        fail("Chat not found; use /sessions and /open <number>")
      }
      self.load_chat(client, chat)
    }
    "/search" => {
      let reply = client.call(@commands.session_search, @protocol.SessionSearchPayload::{
        query: rest,
        include_archived: true,
      })
      self.panel("Chat search", [reply.to_json().stringify(indent=2)])
    }
    "/model" => {
      guard !rest.is_empty() else { fail("Usage: /model <model name>") }
      if chat.codex_id() is Some(_) {
        self.codex_model = Some(rest)
      } else {
        self.model = rest
        self.model_explicit = true
      }
      self.notice = "Model: \{rest}"
    }
    "/thinking" => {
      if chat.codex_id() is Some(_) {
        guard rest is ("none" | "minimal" | "low" | "medium" | "high" | "xhigh") else {
          fail(
            "Usage: /thinking none|minimal|low|medium|high|xhigh (model support varies)",
          )
        }
        self.codex_effort = Some(rest)
        return
      }
      guard @protocol.OpenSeekThinking::parse(
          if rest == "off" {
            "no"
          } else {
            rest
          },
        )
        is Some(thinking) else {
        fail("Usage: /thinking off|high|max")
      }
      self.thinking = thinking
    }
    "/steps" => {
      let steps = @string.parse_int(rest)
      guard steps > 0 else { fail("Step limit must be positive") }
      self.max_steps = Some(steps)
    }
    "/stop" => {
      guard chat.run_id is Some(_) else { fail("No running turn in this chat") }
      ignore(
        client.call(@commands.agent_cancel, @protocol.CancelPayload::{
          run_id: chat.run_id,
        }),
      )
      chat.status = "Stopping…"
    }
    "/compact" => {
      let reply = client.call(@commands.agent_compact, @protocol.CompactPayload::{
        session: chat.key.session,
        workspace: chat.key.workspace,
        model: Some(self.model),
        thinking: Some(self.thinking),
        max_steps: self.max_steps,
      })
      self.notice = if reply.compacting {
        "Compacting…"
      } else {
        "Compaction was not started"
      }
    }
    "/goal" => {
      let auto = rest.has_prefix("auto ")
      let goal = if rest == "clear" {
        None
      } else if auto {
        Some(rest.view(start_offset=5).to_owned())
      } else {
        Some(rest)
      }
      let reply = client.call(@commands.agent_goal, @protocol.GoalPayload::{
        session: chat.key.session,
        workspace: chat.key.workspace,
        text: goal,
        auto: Some(auto),
        model: Some(self.model),
        thinking: Some(self.thinking),
        max_steps: self.max_steps,
      })
      self.notice = if reply.delivered {
        "Goal request sent"
      } else {
        "Goal request was not delivered"
      }
    }
    "/rename" => {
      guard chat.key.workspace is Some(workspace) else {
        fail("Start this chat before renaming it")
      }
      ignore(
        client.call(@commands.session_rename, @protocol.SessionRenamePayload::{
          session: chat.key.session,
          workspace,
          title: rest,
        }),
      )
      chat.title = rest
    }
    "/archive" => {
      let reply = client.call(@commands.session_archive, @protocol.SessionPayload::{
        session: chat.key.session,
        force: Some(rest == "force"),
      })
      match reply {
        Archived(_) => {
          self.start_chat(client, chat.key.workspace)
          self.refresh_sessions(client)
        }
        NeedsForce(checkout) =>
          self.panel(
            "Archive needs confirmation",
            [
              "This will remove checkout \{checkout.worktree} with \{checkout.dirty_path_count} changed paths.",
              ..checkout.dirty_paths,
              "Use /archive force to confirm.",
            ],
          )
      }
    }
    "/unarchive" => {
      ignore(
        client.call(@commands.session_unarchive, @protocol.SessionPayload::{
          session: chat.key.session,
          force: None,
        }),
      )
      self.refresh_sessions(client)
    }
    "/delete" => {
      guard chat.key.workspace is Some(workspace) else {
        fail("No saved chat is selected")
      }
      if chat.key.archived {
        ignore(
          client.call(@commands.session_delete_archived, @protocol.ArchivedSessionPayload::{
            session: chat.key.session,
            workspace,
          }),
        )
      } else {
        let worktree = if rest == "force" {
          let check = client.call(@commands.session_delete_check, @protocol.SessionDeleteCheckPayload::{
            session: chat.key.session,
            workspace,
          })
          check.checkout.map(checkout => checkout.worktree)
        } else {
          None
        }
        let reply = client.call(@commands.session_delete, @protocol.SessionDeletePayload::{
          session: chat.key.session,
          workspace,
          worktree,
          force: Some(rest == "force"),
        })
        if reply is Unconfirmed(checkout) {
          self.panel(
            "Delete needs confirmation",
            [
              "Checkout \{checkout.worktree} has \{checkout.dirty_path_count} changed paths.",
              ..checkout.dirty_paths,
              "Use /delete force to confirm.",
            ],
          )
          return
        }
      }
      self.start_chat(client, chat.key.workspace)
      self.refresh_sessions(client)
    }
    "/fork" => {
      guard chat.key.workspace is Some(workspace) else {
        fail("Start this chat before forking it")
      }
      let reply = client.call(@commands.session_fork, @protocol.SessionForkPayload::{
        session: chat.key.session,
        workspace,
        through: @string.parse_int(rest),
        model: self.model,
        source_title: chat.title,
      })
      self.refresh_sessions(client)
      let key : ChatKey = {
        session: reply.session,
        workspace: Some(workspace),
        archived: false,
      }
      if self.chats.get(key) is Some(forked) {
        self.load_chat(client, forked)
      }
    }
    "/export" | "/share" => {
      guard chat.key.workspace is Some(workspace) else {
        fail("Start this chat first")
      }
      let payload : @protocol.SessionExportPayload = {
        session: chat.key.session,
        workspace,
        title: chat.title,
        archived: chat.key.archived,
      }
      let output = if command == "/export" {
        client.call(@commands.session_export, payload).to_json()
      } else {
        client.call(@commands.session_share, payload).to_json()
      }
      self.panel("Conversation", [output.stringify(indent=2)])
    }
    "/queue" => self.queue_command(client, rest)
    "/approvals" =>
      self.panel(
        "Pending approvals",
        self.approvals
        .iter()
        .filter(item => !item.answered)
        .map(item => {
          "\{item.id} · \{item.tool_name}\n\{item.detail}\n\{item.body.unwrap_or("")}\n/approve \{item.id}  /deny \{item.id}"
        })
        .collect(),
      )
    "/approve" => self.approve(client, rest, true)
    "/deny" => self.approve(client, rest, false)
    "/terminal" =>
      if rest == "close" {
        self.close_terminal(client)
      } else {
        self.open_terminal(
          client,
          if rest.is_empty() {
            None
          } else {
            Some(rest)
          },
        )
      }
    "/edit" => fail("Usage: /edit <file path>")
    _ => {
      let output = @workbench.execute(client, text, self.context())
      self.panel(output.title, output.lines)
      if output.refresh {
        self.refresh_sessions(client)
        if command == "/worktree" {
          if chat.codex_id() is Some(id) {
            self.install_codex(self.codex.read(client, id))
          }
          self.refresh_selected_workspace(client)
        }
      }
    }
  }
}

///|
async fn State::queue_command(
  self : State,
  client : @client.Client,
  rest : String,
) -> Unit {
  let (action, args) = command_parts(rest)
  if action is ("" | "on" | "off") {
    self.queue_followup = action != "off"
    self.notice = if self.queue_followup {
      "Follow-up queues next"
    } else {
      "Follow-up steers now"
    }
    return
  }
  let chat = self.active
  guard chat.run_id is Some(run_id) else {
    fail("No running turn in this chat")
  }
  let (id, text) = command_parts(args)
  let retained_images = chat.queued_drafts
    .get(id)
    .map(submitted => submitted.attachments.copy_images())
    .unwrap_or_else(() => @attachments.Draft())
  let queue_action = match action {
    "edit" =>
      @protocol.QueueEdit(id~, text~, images=retained_images.image_urls())
    "remove" => @protocol.QueueWithdraw(id~)
    "steer" => @protocol.QueueSteer(id~)
    _ => fail("Usage: /queue on|off|edit <id> <text>|remove <id>|steer <id>")
  }
  if action == "steer" && chat.queued_drafts.get(id) is Some(submitted) {
    chat.steering_drafts[id] = { ..submitted, run_id, }
  }
  let reply = client.call(@commands.agent_queue, @protocol.QueuePayload::{
    action: queue_action,
    run_id,
  }) catch {
    @client.ClientError::Rpc(..) as error => {
      if action == "steer" {
        chat.steering_drafts.remove(id)
      }
      raise error
    }
    error => raise error
  }
  guard reply.accepted else {
    if action == "steer" {
      chat.steering_drafts.remove(id)
    }
    fail("Queued message was not changed")
  }
  if action == "edit" {
    if chat.queued.contains(id) {
      chat.queued[id] = text
      chat.queued_drafts[id] = { run_id, text, attachments: retained_images, }
    }
  } else {
    chat.queued.remove(id)
    if action == "remove" {
      chat.queued_drafts.remove(id)
    }
  }
}
