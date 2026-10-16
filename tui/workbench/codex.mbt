///|
fn permission(value : String) -> @protocol.CodexPermissionMode raise InputError {
  match value {
    "ask" => @protocol.RequestApproval
    "auto" => @protocol.AutoReview
    "full" => @protocol.FullAccess
    _ => raise InputError("Permission mode must be ask, auto, or full")
  }
}

///|
fn codex(args : Array[String], context : Context) -> Plan raise InputError {
  let action = args.get(1).unwrap_or("threads")
  match action {
    "status" =>
      request(@commands.codex_status, @protocol.NoPayload, "Codex status")
    "config" =>
      request(
        @commands.codex_config_open,
        @protocol.NoPayload,
        "Codex configuration",
      )
    "models" =>
      request(
        @commands.codex_model_list,
        { limit: 100, include_hidden: false, },
        "Codex models",
      )
    "account" =>
      request(
        @commands.codex_account_read,
        { refresh_token: true, },
        "Codex account",
      )
    "login" =>
      request(
        @commands.codex_account_login_start,
        {
          kind_: "chatgpt",
          use_hosted_login_success_page: true,
          app_brand: "SeekMoon",
        },
        "Codex sign-in · open the authorization URL in your browser",
      )
    "cancel-login" =>
      request(
        @commands.codex_account_login_cancel,
        { login_id: arg(args, 2, "/codex cancel-login LOGIN_ID"), },
        "Codex sign-in cancelled",
      )
    "logout" =>
      request(
        @commands.codex_account_logout,
        @protocol.NoPayload,
        "Codex signed out",
      )
    "threads" | "archived" =>
      request(
        @commands.codex_thread_list,
        { limit: 100, archived: action == "archived", cursor: args.get(2), },
        "Codex conversations",
      )
    "read" =>
      request(
        @commands.codex_thread_read,
        {
          thread_id: arg(args, 2, "/codex read THREAD_ID"),
          include_turns: Some(true),
        },
        "Codex conversation",
      )
    "history" =>
      request(
        @commands.codex_thread_history_read,
        { thread_id: arg(args, 2, "/codex history THREAD_ID"), },
        "Codex history",
      )
    "new" =>
      request(
        @commands.codex_thread_start,
        {
          cwd: context.workspace,
          model: args.get(2),
          draft_id: None,
          permission_mode: permission(args.get(3).unwrap_or("ask")),
        },
        "New Codex conversation",
        refresh=true,
      )
    "resume" =>
      request(
        @commands.codex_thread_resume,
        {
          thread_id: arg(args, 2, "/codex resume THREAD_ID [ask|auto|full]"),
          permission_mode: permission(args.get(3).unwrap_or("ask")),
        },
        "Codex conversation resumed",
        refresh=true,
      )
    "rename" =>
      request(
        @commands.codex_thread_rename,
        {
          thread_id: arg(args, 2, "/codex rename THREAD_ID NAME"),
          name: rest(args, 3, "/codex rename THREAD_ID NAME"),
        },
        "Codex conversation renamed",
        refresh=true,
      )
    "archive" =>
      request(
        @commands.codex_thread_archive,
        {
          thread_id: arg(args, 2, "/codex archive THREAD_ID [--force]"),
          force: args.get(3) == Some("--force"),
        },
        "Codex conversation archived",
        refresh=true,
      )
    "unarchive" =>
      request(
        @commands.codex_thread_unarchive,
        { thread_id: arg(args, 2, "/codex unarchive THREAD_ID"), },
        "Codex conversation restored",
        refresh=true,
      )
    "compact" =>
      request(
        @commands.codex_thread_compact,
        { thread_id: arg(args, 2, "/codex compact THREAD_ID"), },
        "Codex compaction requested",
      )
    "review" =>
      request(
        @commands.codex_review_start,
        {
          thread_id: arg(args, 2, "/codex review THREAD_ID"),
          target: { kind_: "uncommittedChanges", },
        },
        "Codex review started",
      )
    "send" =>
      request(
        @commands.codex_turn_start,
        {
          thread_id: arg(args, 2, "/codex send THREAD_ID TEXT"),
          input: [
            {
              "type": "text",
              "text": rest(args, 3, "/codex send THREAD_ID TEXT"),
            },
          ],
          model: None,
          effort: None,
          cwd: context.workspace,
          permission_mode: @protocol.RequestApproval,
        },
        "Codex turn started",
      )
    "steer" =>
      request(
        @commands.codex_turn_steer,
        {
          thread_id: arg(args, 2, "/codex steer THREAD_ID TURN_ID TEXT"),
          expected_turn_id: arg(args, 3, "/codex steer THREAD_ID TURN_ID TEXT"),
          input: [
            {
              "type": "text",
              "text": rest(args, 4, "/codex steer THREAD_ID TURN_ID TEXT"),
            },
          ],
        },
        "Codex follow-up sent",
      )
    "interrupt" =>
      request(
        @commands.codex_turn_interrupt,
        {
          thread_id: arg(args, 2, "/codex interrupt THREAD_ID TURN_ID"),
          turn_id: arg(args, 3, "/codex interrupt THREAD_ID TURN_ID"),
        },
        "Codex interrupt requested",
      )
    "requests" =>
      request(
        @commands.codex_server_request_list,
        @protocol.NoPayload,
        "Codex approvals and questions",
      )
    "respond" => {
      let request_id = @json.parse(
        arg(args, 3, "/codex respond TOKEN REQUEST_ID_JSON RESULT_JSON"),
      ) catch {
        _ =>
          raise InputError("Request id must be valid JSON (quote a string id)")
      }
      let result = @json.parse(
        rest(args, 4, "/codex respond TOKEN REQUEST_ID_JSON RESULT_JSON"),
      ) catch {
        _ => raise InputError("Response must be valid JSON")
      }
      request(
        @commands.codex_server_request_respond,
        {
          response_token: arg(
            args, 2, "/codex respond TOKEN REQUEST_ID_JSON RESULT_JSON",
          ),
          request_id,
          result,
        },
        "Codex response sent",
      )
    }
    "skills" =>
      request(
        @commands.codex_skills_list,
        {
          thread_id: arg(args, 2, "/codex skills THREAD_ID"),
          cwd: workspace(context),
          force_reload: true,
        },
        "Codex skills",
      )
    _ =>
      raise InputError(
        "Usage: /codex threads|archived|new|read|history|resume|rename|archive|unarchive|send|steer|interrupt|compact|review|models|account|login|logout|requests|respond|skills|status|config",
      )
  }
}
