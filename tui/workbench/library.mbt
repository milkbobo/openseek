///|
fn skills(args : Array[String]) -> Plan raise InputError {
  match args.get(1).unwrap_or("installed") {
    "installed" =>
      request(
        @commands.skills_installed,
        @protocol.NoPayload,
        "Installed skills",
      )
    "catalog" =>
      request(@commands.skills_catalog, @protocol.NoPayload, "Skill catalog")
    "read" =>
      request(
        @commands.skills_installed_content,
        { id: arg(args, 2, "/skills read ID"), },
        "Skill instructions",
      )
    "remove" =>
      request(
        @commands.skills_uninstall,
        { id: arg(args, 2, "/skills remove ID"), },
        "Skill removed",
        refresh=true,
      )
    "show" | "install" => {
      let payload : @protocol.InstallSkillPayload = {
        module_name: arg(
          args, 2, "/skills show|install MODULE VERSION [PACKAGE]",
        ),
        version: arg(args, 3, "/skills show|install MODULE VERSION [PACKAGE]"),
        package_path: args.get(4),
      }
      if args.get(1) == Some("show") {
        request(
          @commands.skills_content, payload, "Published skill instructions",
        )
      } else {
        request(
          @commands.skills_install,
          payload,
          "Skill installed",
          refresh=true,
        )
      }
    }
    _ =>
      raise InputError(
        "Usage: /skills installed|catalog|read ID|remove ID|show MODULE VERSION|install MODULE VERSION",
      )
  }
}

///|
fn schedule(args : Array[String], context : Context) -> Plan raise InputError {
  let action = arg(
    args, 1, "/schedule every MINUTES NAME TASK | once UNIX_MS NAME TASK | pause|resume|run|stop|delete ID",
  )
  match action {
    "every" | "once" => {
      let timing = arg(
        args, 2, "/schedule every MINUTES NAME TASK | once UNIX_MS NAME TASK",
      )
      let timing : @protocol.ScheduleTiming = if action == "every" {
        let minutes = positive(timing, "Interval")
        guard minutes <= 525600 else {
          raise InputError("Interval must be at most 525600 minutes")
        }
        @protocol.Every(minutes)
      } else {
        let at = @string.parse_int64(timing) catch {
          _ => raise InputError("Time must be a Unix timestamp in milliseconds")
        }
        guard at >= 0L else { raise InputError("Time must be nonnegative") }
        @protocol.Once(at)
      }
      request(
        @commands.schedules_save,
        {
          id: None,
          spec: {
            name: arg(
              args, 3, "/schedule every MINUTES NAME TASK | once UNIX_MS NAME TASK",
            ),
            workspace: context.workspace,
            task: rest(
              args, 4, "/schedule every MINUTES NAME TASK | once UNIX_MS NAME TASK",
            ),
            model: Some(context.model),
            timing,
            timeout_minutes: 60,
          },
          run_now: false,
        },
        "Scheduled task saved",
      )
    }
    "pause" | "resume" | "run" | "stop" | "delete" =>
      request(
        @commands.schedules_action,
        {
          id: arg(args, 2, "/schedule pause|resume|run|stop|delete ID"),
          action,
        },
        "Scheduled tasks",
      )
    _ =>
      raise InputError(
        "Usage: /schedule every MINUTES NAME TASK | once UNIX_MS NAME TASK | pause|resume|run|stop|delete ID",
      )
  }
}

///|
fn jobs(args : Array[String], context : Context) -> Plan raise InputError {
  let scope = job_scope(context)
  match args.get(1).unwrap_or("list") {
    "list" =>
      request(
        @commands.jobs_list,
        {
          scope,
          offset: if args.get(2) is Some(offset) {
            number(offset, "Offset")
          } else {
            0
          },
          selected: None,
        },
        "Background jobs",
      )
    "read" | "stop" => {
      let target : @protocol.JobTarget = {
        scope,
        generation: arg(args, 2, "/jobs read|stop GENERATION ID [OFFSET]"),
        job_id: arg(args, 3, "/jobs read|stop GENERATION ID [OFFSET]"),
      }
      if args.get(1) == Some("stop") {
        request(@commands.jobs_stop, target, "Job stopped")
      } else {
        let offset = if args.get(4) is Some(offset) {
          Some(
            @string.parse_int64(offset) catch {
              _ => raise InputError("Offset must be an integer")
            },
          )
        } else {
          None
        }
        request(
          @commands.jobs_read,
          { target, offset, limit: 32768, },
          "Job output",
        )
      }
    }
    _ =>
      raise InputError(
        "Usage: /jobs list [OFFSET]|read GENERATION ID [OFFSET]|stop GENERATION ID",
      )
  }
}

///|
fn auth(args : Array[String]) -> Plan raise InputError {
  match args.get(1).unwrap_or("status") {
    "status" =>
      request(@commands.auth_status, @protocol.NoPayload, "Remote access")
    "connect" =>
      request(
        @commands.auth_connect,
        @protocol.NoPayload,
        "Connect remote access",
      )
    "cancel" =>
      request(@commands.auth_cancel, @protocol.NoPayload, "Sign-in cancelled")
    "disconnect" =>
      request(
        @commands.auth_disconnect,
        @protocol.NoPayload,
        "Remote access disconnected",
      )
    _ => raise InputError("Usage: /auth status|connect|cancel|disconnect")
  }
}
