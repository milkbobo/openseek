///|
/// Parse a user action into a typed request. No method name or arbitrary JSON
/// supplied by the user crosses the command boundary.
pub fn plan(text : String, context : Context) -> Plan raise InputError {
  let args = words(text)
  let command = arg(args, 0, "/help")
  match command {
    "/settings" =>
      request(@commands.settings_get, @protocol.NoPayload, "Engine settings")
    "/provider" => {
      let provider = arg(
        args, 1, "/provider deepseek|glm|openrouter|custom [URL]",
      )
      let patch = settings_patch()
      let patch = match provider {
        "deepseek" | "glm" => { ..patch, provider: Some(provider), }
        "openrouter" =>
          {
            ..patch,
            provider: Some("custom"),
            custom_api_url: Some(
              "https://openrouter.ai/api/v1/chat/completions",
            ),
          }
        "custom" =>
          {
            ..patch,
            provider: Some("custom"),
            custom_api_url: Some(arg(args, 2, "/provider custom URL")),
          }
        _ =>
          raise InputError(
            "Provider must be deepseek, glm, openrouter, or custom",
          )
      }
      request(@commands.settings_set, patch, "Provider saved", refresh=true)
    }
    "/key" => {
      let provider = arg(
        args, 1, "/key deepseek|glm|custom KEY (empty quoted key clears)",
      )
      guard args.get(2) is Some(key) else {
        raise InputError("Usage: /key deepseek|glm|custom KEY")
      }
      let patch = settings_patch()
      let patch = match provider {
        "deepseek" => { ..patch, deepseek_api_key: Some(key), }
        "glm" => { ..patch, glm_api_key: Some(key), }
        "custom" | "openrouter" => { ..patch, custom_api_key: Some(key), }
        _ => raise InputError("Key provider must be deepseek, glm, or custom")
      }
      request(@commands.settings_set, patch, "API key saved", refresh=true)
    }
    "/followup" => {
      let behavior = arg(args, 1, "/followup steer|queue")
      guard behavior is ("steer" | "queue") else {
        raise InputError("Follow-up behavior must be steer or queue")
      }
      request(
        @commands.settings_set,
        { ..settings_patch(), followup_behavior: Some(behavior), },
        "Follow-up behavior saved",
        refresh=true,
      )
    }
    "/workspaces" =>
      request(@commands.workspace_list, @protocol.NoPayload, "Workspaces")
    "/workspace" => {
      let action = arg(args, 1, "/workspace add|remove PATH")
      let path = arg(args, 2, "/workspace add|remove PATH")
      match action {
        "add" =>
          request(
            @commands.workspace_add,
            { path, },
            "Workspace added",
            refresh=true,
          )
        "remove" =>
          request(
            @commands.workspace_remove,
            { path, },
            "Workspace removed",
            refresh=true,
          )
        _ => raise InputError("Usage: /workspace add|remove PATH")
      }
    }
    "/workspace-settings" => workspace_settings(args, context)
    "/worktree" => worktree(args, context)
    "/skills" => skills(args)
    "/schedules" =>
      request(@commands.schedules_list, @protocol.NoPayload, "Scheduled tasks")
    "/schedule" => schedule(args, context)
    "/jobs" => jobs(args, context)
    "/files" => {
      let path = if args.get(1) is Some(path) {
        if path.has_prefix("/") {
          path
        } else {
          workspace(context) + "/" + path
        }
      } else {
        workspace(context)
      }
      request(@commands.fs_read_directory, { path, }, "Files · " + path)
    }
    "/browse" =>
      request(@commands.fs_browse, { path: args.get(1), }, "Directory picker")
    "/mkdir" =>
      request(
        @commands.fs_create_directory,
        { parent: workspace(context), name: arg(args, 1, "/mkdir NAME"), },
        "Directory created",
      )
    "/file" | "/read" =>
      request(
        @commands.fs_read_file,
        {
          path: arg(args, 1, "/file PATH"),
          root: if arg(args, 1, "/file PATH").has_prefix("/") {
            None
          } else {
            context.workspace
          },
        },
        "File preview",
      )
    "/find" =>
      request(
        @commands.fs_search_files,
        {
          path: workspace(context),
          cache_key: "seekmoon-tui-files",
          query: rest(args, 1, "/find QUERY"),
          max_results: 100,
          generation: next_search_generation(),
        },
        "Quick Open",
      )
    "/grep" => search(args, context, semantic=false)
    "/semantic" => search(args, context, semantic=true)
    "/git" => git(args, context)
    "/history" =>
      request(
        @commands.git_history,
        {
          session: context.session,
          workspace: context.workspace,
          snapshot: None,
          skip: if args.get(1) is Some(value) {
            number(value, "Offset")
          } else {
            0
          },
          limit: 100,
        },
        "Git history",
      )
    "/diff" => diff_plan(args, context)
    "/definition" | "/references" => navigation(command, args, context)
    "/symbols" =>
      request(
        @commands.lsp_workspace_symbols,
        {
          session: context.session,
          root: workspace(context),
          query: rest(args, 1, "/symbols QUERY"),
        },
        "Workspace symbols",
      )
    "/diagnostics" =>
      request(
        @commands.lsp_open,
        {
          session: context.session,
          root: workspace(context),
          path: arg(args, 1, "/diagnostics PATH"),
        },
        "MoonBit diagnostics",
      )
    "/hover" =>
      request(
        @commands.lsp_hover,
        {
          session: context.session,
          root: workspace(context),
          path: arg(args, 1, "/hover PATH LINE COLUMN"),
          line: positive(arg(args, 2, "/hover PATH LINE COLUMN"), "Line") - 1,
          character: positive(arg(args, 3, "/hover PATH LINE COLUMN"), "Column") -
          1,
        },
        "Symbol information",
      )
    "/packages" =>
      request(
        @commands.moon_package_graph,
        {
          session: context.session,
          root: workspace(context),
          path: args.get(1).unwrap_or("moon.mod"),
        },
        "MoonBit package graph",
      )
    "/attach" =>
      request(
        @commands.fs_import_attachment,
        {
          session: context.session,
          workspace: workspace(context),
          source: @protocol.AttachmentPath(arg(args, 1, "/attach PATH")),
        },
        "Attachment imported · mention the returned path in your prompt",
      )
    "/github" => github(args, context)
    "/codex" => codex(args, context)
    "/auth" => auth(args)
    "/export" | "/share" => {
      let payload : @protocol.SessionExportPayload = {
        session: context.session,
        workspace: workspace(context),
        title: args.get(1).unwrap_or(context.session),
        archived: context.archived,
      }
      if command == "/share" {
        request(@commands.session_share, payload, "Conversation shared")
      } else {
        request(@commands.session_export, payload, "Conversation exported")
      }
    }
    "/search" =>
      request(
        @commands.session_search,
        { query: rest(args, 1, "/search TITLE"), include_archived: true, },
        "Conversation search",
      )
    _ =>
      raise InputError(
        "Unknown command " + command + ". Use /help for the command list.",
      )
  }
}

///|
fn workspace_settings(
  args : Array[String],
  context : Context,
) -> Plan raise InputError {
  let path = workspace(context)
  if args.length() == 1 {
    return request(
      @commands.workspace_settings_get,
      { workspace: path, },
      "Workspace settings",
    )
  }
  let setting = arg(
    args, 1, "/workspace-settings worktrees|submodules|timeout VALUE",
  )
  let value = arg(
    args, 2, "/workspace-settings worktrees|submodules|timeout VALUE",
  )
  let payload : @protocol.WorkspaceSettingsSetPayload = {
    workspace: path,
    worktree_mode: None,
    checkout_submodules: None,
    submodule_checkout_timeout_seconds: None,
  }
  let payload = match setting {
    "worktrees" => { ..payload, worktree_mode: Some(boolean(value)), }
    "submodules" => { ..payload, checkout_submodules: Some(boolean(value)), }
    "timeout" =>
      {
        ..payload,
        submodule_checkout_timeout_seconds: Some(positive(value, "Timeout")),
      }
    _ => raise InputError("Setting must be worktrees, submodules, or timeout")
  }
  request(
    @commands.workspace_settings_set,
    payload,
    "Workspace settings saved",
    refresh=true,
  )
}

///|
fn worktree(args : Array[String], context : Context) -> Plan raise InputError {
  let path = workspace(context)
  match args.get(1).unwrap_or("list") {
    "list" =>
      request(@commands.worktree_list, { workspace: path, }, "Worktrees")
    "create" | "repair" =>
      request(
        @commands.worktree_create,
        { workspace: path, session: Some(context.session), codex_thread: None, },
        "Conversation worktree",
        refresh=true,
      )
    "remove" =>
      request(
        @commands.worktree_remove,
        {
          workspace: path,
          name: arg(args, 2, "/worktree remove NAME [--force]"),
          force: if args.get(3) == Some("--force") {
            Some(true)
          } else {
            None
          },
        },
        "Worktree removed",
        refresh=true,
      )
    _ =>
      raise InputError(
        "Usage: /worktree list|create|repair|remove NAME [--force]",
      )
  }
}
