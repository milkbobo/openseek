///|
async fn serve_image_attachment(
  socket : @websocket.Conn,
  name : String,
) -> Unit {
  let (id, _) = terminal_request(socket, "worktree.list")
  socket.send_text(
    (
      {
        "jsonrpc": "2.0",
        "id": id,
        "result": @protocol.WorktreesReply::{ worktrees: [], }.to_json(),
      } : Json).stringify(),
  )
  let (id, _) = terminal_request(socket, "fs.prepare_attachment")
  let url = "data:image/png;base64," +
    (if name == "original.png" { "AA==" } else { "AQ==" })
  socket.send_text(
    (
      {
        "jsonrpc": "2.0",
        "id": id,
        "result": @protocol.AttachmentImage(name~, url~).to_json(),
      } : Json).stringify(),
  )
}

///|
async test "dropped rich steer restores exact local submission once before a late acceptance reply" {
  let release : @async.Queue[Unit] = Queue(kind=Blocking(1))
  with_terminal_peer(
    socket => {
      serve_image_attachment(socket, "original.png")
      let (id, params) = terminal_request(socket, "agent.steer")
      let payload : @protocol.SteerPayload = @json.from_json(params)
      assert_eq(payload.images, ["data:image/png;base64,AA=="])
      let event = @protocol.Notification::AgentEvent({
        session: "steer-restore",
        run_id: Some("run-1"),
        event: @agent_protocol.Event::SteerDropped(
          content=Content([
            Text("wire text must not replace the captured draft"),
          ]),
          submission_id=payload.submission_id,
        ),
      })
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "method": event.wire_name(),
            "params": event.params(),
          } : Json).stringify(),
      )
      serve_image_attachment(socket, "newer.png")
      release.get()
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "id": id,
            "result": @protocol.SteerReply::{
              steered: true,
              run_id: Some("run-1"),
            }.to_json(),
          } : Json).stringify(),
      )
    },
    client => {
      let state = State(Some("/one"))
      let chat = state.active
      chat.key = { ..chat.key, session: "steer-restore", }
      chat.loaded = true
      chat.run_id = Some("run-1")
      chat.draft.set_text("submitted draft")
      state.attach(client, "original.png")
      @async.with_task_group(group => {
        let sending = group.spawn(() => {
          state.send_prompt(client, "submitted draft")
        })
        let event = client.receive()
        assert_true(chat.draft.is_empty())
        assert_true(chat.attachments.is_empty())
        chat.draft.set_text("newer text")
        state.attach(client, "newer.png")
        state.notification(event)
        assert_eq(chat.draft.text(), "submitted draft\n\nnewer text")
        assert_eq(chat.attachments.labels(), [
          "Image · original.png", "Image · newer.png",
        ])
        assert_true(chat.steering_drafts.is_empty())
        let notices = chat.rows.length()
        state.notification(event)
        assert_eq(chat.rows.length(), notices)
        assert_eq(chat.attachments.labels().length(), 2)
        release.put(())
        sending.wait()
        assert_eq(chat.draft.text(), "submitted draft\n\nnewer text")
        assert_eq(chat.attachments.labels().length(), 2)
      })
    },
  )
}

///|
test "steer refusal ignores foreign legacy and predecessor ids and merges newer text once" {
  let chat = test_chat("/one")
  chat.draft.set_text("original")
  chat.remember_steer("local", "run-1", "original")
  chat.draft.set_text("newer")
  for
    event in [
      @agent_protocol.Event::SteerDropped(
        content=Content([Text("foreign")]),
        submission_id=Some("other"),
      ),
      @agent_protocol.Event::SteerDropped(
        content=Content([Text("legacy")]),
        submission_id=None,
      ),
    ] {
    chat.stream(event, run_id=Some("run-1"))
  }
  let owned = @agent_protocol.Event::SteerDropped(
    content=Content([Text("untrusted")]),
    submission_id=Some("local"),
  )
  chat.stream(owned, run_id=Some("run-2"))
  assert_eq(chat.draft.text(), "newer")
  assert_true(chat.rows.is_empty())
  chat.stream(owned, run_id=Some("run-1"))
  assert_eq(chat.draft.text(), "original\n\nnewer")
  chat.stream(owned, run_id=Some("run-1"))
  assert_eq(chat.rows.length(), 1)
}

///|
test "finished runs retire captured steers so trailing drops do not reopen the draft" {
  let state = State(Some("/one"))
  let chat = state.active
  chat.run_id = Some("run-1")
  chat.draft.set_text("old draft")
  chat.remember_steer("old", "run-1", "old draft")
  state.notification(
    AgentFinished({
      run_id: "run-1",
      status: "completed",
      answer: None,
      exit_code: None,
    }),
  )
  assert_true(chat.steering_drafts.is_empty())
  chat.stream(
    SteerDropped(
      content=Content([Text("old draft")]),
      submission_id=Some("old"),
    ),
    run_id=Some("run-1"),
  )
  assert_true(chat.draft.is_empty())
  assert_true(chat.rows.is_empty())
}

///|
async test "explicitly steering a queued image restores its retained draft when the engine drops it" {
  let release : @async.Queue[Unit] = Queue(kind=Blocking(1))
  with_terminal_peer(
    socket => {
      serve_image_attachment(socket, "original.png")
      let (edit_id, params) = terminal_request(socket, "agent.queue")
      let edit : @protocol.QueuePayload = @json.from_json(params)
      assert_true(
        edit.action
        is QueueEdit(id="queued-image", text="revised task", images~) &&
        images == ["data:image/png;base64,AA=="],
      )
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "id": edit_id,
            "result": @protocol.QueueReply::{ accepted: true, }.to_json(),
          } : Json).stringify(),
      )
      let (id, params) = terminal_request(socket, "agent.queue")
      let payload : @protocol.QueuePayload = @json.from_json(params)
      assert_true(payload.action is QueueSteer(id="queued-image"))
      let event = @protocol.Notification::AgentEvent({
        session: "queue-image-restore",
        run_id: Some("run-1"),
        event: @agent_protocol.Event::SteerDropped(
          content=Content([]),
          submission_id=Some("queued-image"),
        ),
      })
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "method": event.wire_name(),
            "params": event.params(),
          } : Json).stringify(),
      )
      release.get()
      socket.send_text(
        (
          {
            "jsonrpc": "2.0",
            "id": id,
            "result": @protocol.QueueReply::{ accepted: true, }.to_json(),
          } : Json).stringify(),
      )
    },
    client => {
      let state = State(Some("/one"))
      let chat = state.active
      chat.key = { ..chat.key, session: "queue-image-restore", }
      chat.run_id = Some("run-1")
      state.attach(client, "original.png")
      chat.queued["queued-image"] = "queued task"
      chat.queued_drafts["queued-image"] = {
        run_id: "run-1",
        text: "queued task",
        attachments: chat.attachments.copy(),
      }
      chat.attachments.clear()
      state.queue_command(client, "edit queued-image revised task")
      @async.with_task_group(group => {
        let steering = group.spawn(() => {
          state.queue_command(client, "steer queued-image")
        })
        state.notification(client.receive())
        assert_eq(chat.draft.text(), "revised task")
        assert_eq(chat.attachments.labels(), ["Image · original.png"])
        release.put(())
        steering.wait()
        assert_eq(chat.attachments.labels(), ["Image · original.png"])
        assert_true(chat.queued.is_empty())
      })
    },
  )
}
