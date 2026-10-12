///|
/// Exercise the public actor API with a child that snapshots its MCP file at
/// startup, just like serve. The gate keeps turn one open while two follow-ups
/// are queued and the file changes. Black-box tests run in their own process,
/// so this HOME does not race the engine's package-private environment tests.
#cfg(not(platform="windows"))
async test "queued prompts reload MCP edits creation and deletion without losing the queue" {
  let previous_home = @sys.get_env_var("HOME")
  defer (match previous_home {
    Some(home) => @sys.set_env_var("HOME", home)
    None => @sys.unset_env_var("HOME")
  })
  let root = @fs.realpath(@fs.tmpdir(prefix="openseek-queued-mcp-"))
  defer @fs.rmdir(root, recursive=true)
  for
    index, (before, after, fail_spawn, hold_goal) in [
      (Some("alpha"), Some("beta"), false, false),
      (None, Some("beta"), false, false),
      (Some("alpha"), None, false, false),
      (Some("alpha"), Some("alpha"), false, false),
      (Some("alpha"), Some("beta"), true, false),
      (Some("alpha"), Some("beta"), false, true),
    ] {
    let dir = "\{root}/case-\{index}"
    @sys.set_env_var("HOME", dir)
    @fs.mkdir("\{dir}/.openseek", recursive=true)
    let mcp = "\{dir}/.openseek/mcp.json"
    if before is Some(name) {
      @fs.write_file(mcp, queued_mcp_json(name), create_mode=CreateOrTruncate)
    }
    let program = "\{dir}/engine.sh"
    @fs.write_file(
      program,
      (
        #|#!/bin/sh
        #|loaded=none
        #|for arg in "$@"; do
        #|  case "$arg" in
        #|    --mcp-config=*)
        #|      text=$(cat "${arg#--mcp-config=}") || exit 1
        #|      case "$text" in *beta*) loaded=beta;; *) loaded=alpha;; esac
        #|      ;;
        #|  esac
        #|done
        #|while IFS= read -r line; do
        #|  case "$line" in *'"command":"prompt"'*) ;; *) continue;; esac
        #|  printf '{"event":"assistant_message","content":"%s:%s"}\n' "$$" "$loaded"
        #|  while [ ! -f "$HOME/release" ]; do sleep 0.01; done
        #|  printf '%s\n' '{"event":"agent_finished","answer":"done"}'
        #|  while [ -f "$HOME/hold-goal" ] && [ ! -f "$HOME/goal-release" ]; do sleep 0.01; done
        #|done
      ),
      create_mode=CreateOrTruncate,
      permission=0o755,
    )
    @fs.mkdir("\{dir}/runtime", recursive=true)
    @fs.mkdir("\{dir}/workspace", recursive=true)
    ignore(@engine.attach_workspace("\{dir}/workspace", _ => ()))
    @store.SessionStore("\{dir}/workspace/.openseek").create(
      Session(SessionId("queued-mcp"), system_prompt="test"),
    )
    let actor = @engine.new_engine_actor(
      program,
      runtime_dir=Path("\{dir}/runtime"),
    )
    let manager = actor.manager()
    ignore(
      @engine.update_settings(manager, {
        provider: Some("custom"),
        custom_api_url: Some("https://example.invalid/chat/completions"),
        deepseek_api_key: None,
        glm_api_key: None,
        custom_api_key: None,
      }),
    )
    let connected : @async.Queue[Unit] = Queue(kind=Unbounded)
    let messages : @async.Queue[String] = Queue(kind=Unbounded)
    let finished : @async.Queue[String] = Queue(kind=Unbounded)
    let starts : Array[@protocol.StartedPayload] = []
    let errors : Array[String] = []
    let sink = @engine.EventSink(event => {
      match event {
        Connected(_) =>
          ignore(
            connected.try_put(()) catch {
              error => {
                errors.push("\{error}")
                false
              }
            },
          )
        Started(payload) => starts.push(payload)
        StreamEvent({ event: AssistantMessage(content~), .. }) =>
          ignore(
            messages.try_put(content) catch {
              error => {
                errors.push("\{error}")
                false
              }
            },
          )
        Finished(payload) =>
          ignore(
            finished.try_put(payload.run_id) catch {
              error => {
                errors.push("\{error}")
                false
              }
            },
          )
        Error(payload) => errors.push(payload.message.unwrap_or("engine error"))
        _ => ()
      }
    })
    @async.with_timeout(15000, () => {
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          actor.run(sink, message => errors.push(message))
        })
        connected.get()
        let first = @engine.start_run(sink, manager, {
          task: "first",
          images: [],
          submission_id: Some("first"),
          model: None,
          thinking: None,
          max_steps: None,
          session: "queued-mcp",
          workspace: Some("\{dir}/workspace"),
        })
        let initial = messages.get()
        for id in ["second", "third"] {
          assert_true(
            @engine.queue_run(manager, {
              run_id: first.run_id,
              action: QueueAdd(id~, text=id, images=[]),
            }).accepted,
          )
        }
        let goal_task = if hold_goal {
          @fs.write_file("\{dir}/hold-goal", "", create_mode=CreateOrTruncate)
          Some(
            group.spawn(() => {
              @engine.goal_run(manager, {
                session: "queued-mcp",
                text: Some("x".repeat(1_000_000)),
                auto: None,
                model: None,
                thinking: None,
                max_steps: None,
                workspace: Some("\{dir}/workspace"),
              })
            }),
          )
        } else {
          None
        }
        if goal_task is Some(task) {
          @async.sleep(50)
          assert_true(task.try_wait() is None)
        }
        match after {
          Some(name) =>
            @fs.write_file(
              mcp,
              queued_mcp_json(name),
              create_mode=CreateOrTruncate,
            )
          None => @fs.remove(mcp)
        }
        if fail_spawn {
          @fs.remove(program)
        }
        @fs.write_file("\{dir}/release", "", create_mode=CreateOrTruncate)
        assert_eq(finished.get(), first.run_id)
        if goal_task is Some(task) {
          // The terminal has arrived while the goal's large write is still
          // blocked. Promotion must wait and retain both queued prompts.
          @async.sleep(30)
          assert_true(task.try_wait() is None)
          assert_eq(starts.length(), 1)
          assert_eq(errors, [])
          @fs.write_file(
            "\{dir}/goal-release",
            "",
            create_mode=CreateOrTruncate,
          )
          assert_true(task.wait().delivered)
        }
        if fail_spawn {
          let failed = finished.get()
          assert_eq(starts.length(), 2)
          assert_eq(starts[1].submission_id, Some("second"))
          assert_eq(starts[1].run_id, failed)
          assert_eq(errors.length(), 1)
          assert_true(errors[0].contains("failed to start queued prompt"))
          assert_true(messages.try_get() is None)
          return
        }
        let second = messages.get()
        let third = messages.get()
        for _ in 0..<2 {
          ignore(finished.get())
        }
        assert_eq(starts.map(start => start.submission_id), [
          Some("first"),
          Some("second"),
          Some("third"),
        ])
        assert_eq(errors, [])
        assert_eq(second, third)
        assert_true(initial.has_suffix(":" + before.unwrap_or("none")))
        assert_true(second.has_suffix(":" + after.unwrap_or("none")))
        let initial_pid = initial.split(":").next()
        let second_pid = second.split(":").next()
        assert_eq(initial_pid == second_pid, before == after)
      })
    })
  }
}

///|
fn queued_mcp_json(name : String) -> String {
  ({ "mcpServers": { "test": { "command": name } } } : Json).stringify()
}
