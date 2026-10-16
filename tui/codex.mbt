///|
fn Chat::codex_id(self : Chat) -> String? {
  self.key.session.strip_prefix("codex:").map(id => id.to_owned())
}

///|
fn State::install_codex(
  self : State,
  thread : @codexchat.Thread,
  select~ : Bool = false,
) -> Unit {
  let workspace = if thread.project_root is Some(path) && !path.is_empty() {
    Some(path)
  } else {
    thread.cwd
  }
  let key : ChatKey = {
    session: "codex:" + thread.id,
    workspace,
    archived: thread.archived,
  }
  let chat = self.chats
    .values()
    .iter()
    .find_first(chat => chat.codex_id() == Some(thread.id))
    .unwrap_or_else(() => Chat(key, title=thread.title))
  let old_key = chat.key
  self.chats.remove(old_key)
  chat.key = key
  self.chats[key] = chat
  self.sidebar = self.sidebar.map(item => {
    if item == old_key {
      key
    } else {
      item
    }
  })
  chat.rows.clear()
  for message in thread.messages {
    chat.rows.push({
      kind: match message.role {
        "user" => User
        "assistant" => Assistant
        "reasoning" => Reasoning(message.id)
        "error" => Error
        "tool" =>
          Tool(
            message.tool.unwrap_or_else(() => {
              @toolcall.Call(
                message.id,
                "tool",
                output=message.text,
                status=if message.complete { Succeeded } else { Pending },
              )
            }),
          )
        _ => Notice
      },
      label: if message.role == "assistant" {
        "Codex"
      } else {
        message.role
      },
      text: message.text + (if message.complete { "" } else { " ▍" }),
      sequence: None,
    })
  }
  chat.title = thread.title
  chat.run_id = thread.turn_id
  chat.status = thread.status
  chat.loaded = true
  if !self.sidebar.contains(key) {
    self.sidebar.push(key)
  }
  if select {
    self.workspace.clear()
    self.active = chat
    self.pages.close()
    self.sidebar_index = self.sidebar.search(key).unwrap_or(0)
    self.panel_title = None
    self.terminal_visible = false
    self.focus = Composer
  }
}

///|
async fn State::codex_command(
  self : State,
  client : @client.Client,
  rest : String,
) -> Unit {
  let (command, args) = command_parts(rest)
  match command {
    "" | "list" => {
      for thread in self.codex.list(client, archived=args == "archived") {
        self.install_codex(thread)
      }
      self.focus = Sidebar
      self.sidebar_visible = true
      self.notice = "Select a Codex conversation or use /codex new"
    }
    "new" => {
      let thread = self.codex.start(
        client,
        cwd?=self.active.key.workspace,
        model?=self.codex_model,
      )
      self.install_codex(thread, select=true)
      self.active.codex_place_pending = true
      self.refresh_selected_workspace(client)
    }
    "open" => {
      let thread = self.codex.read(client, args)
      self.install_codex(thread, select=true)
      self.refresh_selected_workspace(client)
    }
    "approve" | "deny" => {
      self.codex.sync_requests(client)
      guard self.codex
        .requests()
        .iter()
        .find_first(request => request.response_token == args)
        is Some(request) else {
        fail("No pending Codex request with that token; use /codex requests")
      }
      guard request.approval_result(command == "approve") is Some(result) else {
        fail("This request needs an answer; use /codex respond TOKEN JSON")
      }
      self.codex.respond(client, args, result)
      self.notice = "Decision sent"
    }
    "requests" => {
      self.codex.sync_requests(client)
      self.panel(
        "Codex questions",
        self.codex
        .requests()
        .map(request => {
          "\{request.response_token} · \{request.method_}\n\{request.params.stringify(indent=2)}\n/codex approve \{request.response_token}  /codex deny \{request.response_token}"
        }),
      )
    }
    "respond" => {
      let (token, result) = command_parts(args)
      self.codex.respond(client, token, @json.parse(result))
      self.notice = "Answer sent"
    }
    _ => {
      let output = @workbench.execute(client, "/codex " + rest, self.context())
      self.panel(output.title, output.lines)
    }
  }
}
