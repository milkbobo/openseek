///|
/// Reserve the next turn before yielding, then check MCP in a sibling of the
/// stdout consumer. Replacing the process waits for that consumer's retirement,
/// so doing the replacement inside the consumer would wait on itself.
fn[G] ServeEngine::promote_queued(
  self : ServeEngine,
  manager : EngineManager,
  group : @async.TaskGroup[G],
  next : QueuedRun,
) -> Unit raise {
  let claim = try {
    let sessions = manager.serving()
    let slot = slot_for(sessions, self.session_key)
    if slot.pending is Some(current) &&
      current.op is GoalPending &&
      current.next_start is None {
      let claim : PendingClaim = {
        epoch: sessions,
        session_key: self.session_key,
        op: StartPending,
        active: true,
        next_start: None,
      }
      current.next_start = Some(claim)
      claim
    } else {
      slot.claim(sessions, self.session_key, StartPending)
    }
  } catch {
    error => {
      self.fail_queued(next, "failed to start queued prompt: \{error}")
      return
    }
  }
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    defer claim.release(manager)
    let mut submitted = false
    let mut failure = "engine host stopped before the queued prompt started"
    defer (if !submitted { self.fail_queued(next, failure) })
    try {
      // A goal write or title update may still be finishing when the turn
      // ends. Keep the queue's reservation while those operations release
      // their ownership; temporary contention must not discard the queue.
      while !claim.is_current(manager) {
        guard claim.active &&
          manager.pump is Serving(sessions~) &&
          physical_equal(sessions, claim.epoch) else {
          raise EngineError("engine host restarted before the queued prompt")
        }
        @async.sleep(10)
      }
      while manager.record_guard(self.session_key).active_ops > 0 {
        @async.sleep(10)
        claim.require_current(manager)
      }
      let record_guard = manager.begin_record_op(self.session_key)
      defer manager.end_record_op(self.session_key, record_guard)
      let config = { ..self.config, mcp_config: resolved_mcp_config(), }
      claim.require_current(manager)
      let slot = slot_for(claim.epoch, self.session_key)
      guard slot.live() is Some(current) && physical_equal(current, self) else {
        raise EngineError("engine exited before the queued prompt started")
      }
      if engine_fingerprint(config) != engine_fingerprint(self.config) {
        if handle_spawn_command(
            sink=self.sink,
            group~,
            manager~,
            sessions=claim.epoch,
            claim~,
            config~,
          )
          is Some(error) {
          raise error
        }
      }
      claim.require_current(manager)
      guard slot.live() is Some(live) && live.phase is Idle(..) else {
        raise EngineError("engine is unavailable for the queued prompt")
      }
      guard live.submit(
        @protocol.prompt(next.content, submission_id=next.id),
        failure_reason="failed to promote queued prompt",
      ) else {
        raise EngineError("failed to submit queued prompt")
      }
      ignore(self.queued_runs.remove(0))
      if !physical_equal(live, self) {
        live.queued_runs.append(self.queued_runs)
        self.queued_runs.clear()
      }
      live.phase = Running(run_id=next.run_id, compact_queued=false)
      live.steer_runs.begin_run()
      submitted = true
      live.announce_queued(next)
    } catch {
      error => failure = "failed to start queued prompt: \{error}"
    }
  })
}

///|
fn ServeEngine::announce_queued(
  self : ServeEngine,
  next : QueuedRun,
) -> Unit raise {
  emit(
    self.sink,
    Started({
      run_id: next.run_id,
      submission_id: Some(next.id),
      engine: Some(self.engine_name),
      model: Some(self.model),
      max_steps: Some(self.max_steps),
      session: self.session_key,
      session_root: self.session_root.map(root => root.resource_path()),
    }),
  )
}

///|
/// No prompt reached stdin. Publish a terminal lifecycle for its reserved id
/// so clients also release the queued inputs instead of waiting indefinitely.
fn ServeEngine::fail_queued(
  self : ServeEngine,
  next : QueuedRun,
  reason : String,
) -> Unit raise {
  self.queued_runs.clear()
  self.announce_queued(next)
  emit_error(self.sink, reason, run_id=next.run_id)
  emit_finished(self.sink, next.run_id, Failed)
}
