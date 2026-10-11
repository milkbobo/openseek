// One remote client's connection: JSON-RPC 2.0 (docs/remote-protocol.md)
// over whatever channel reached this host — a WebSocket it dialed out through
// the relay, one it accepted on the console listener, or a byte stream
// (`transport.mbt`). Requests fan out to the shared dispatcher concurrently;
// notifications flow back from the hub. The window bridge is the only other
// way in, and everything below the envelope is the typed Endpoint selected
// from `@api.endpoints`.

///|
/// Everything the single writer task sends, encoded only at the writer so
/// no other task ever touches the channel.
priv enum Outgoing {
  // A complete JSON-RPC response envelope, built where the request ran.
  Response(Json)
  Notify(@protocol.Notification)
  // Transport-level keepalive, serialized with every envelope.
  Ping
  // The reader met a request over the size limit. The writer says so and
  // ends the connection, after whatever was queued ahead of it.
  RefuseOversized
}

///|
/// The outbound queue and hub subscription that make one remote client.
/// Opening them also installs the readiness frame: because the fresh bounded
/// outbound queue is empty, that `put` cannot suspend, so no hub publisher
/// can run between subscribe and readiness. Forwarders may only start after
/// this returns.
priv struct ClientSubscription {
  out : @async.Queue[Outgoing]
  notifications : @broadcast.Subscription[@protocol.Notification]
}

///|
/// One client's actor: a relay data socket this host dials (`run`), or a
/// channel it was handed (`serve`). Its subscription, outbound queue, writer,
/// notification forwarder, pinger, and request tasks cannot outlive the
/// channel.
priv struct ClientActor {
  state : @api.ApiState
  host_connection : @host.HostConnection
}

///|
fn ClientActor::ClientActor(state : @api.ApiState) -> ClientActor {
  { state, host_connection: HostConnection(), }
}

///|
async fn ClientActor::open_subscription(
  self : ClientActor,
) -> ClientSubscription {
  let out : @async.Queue[Outgoing] = Queue(kind=Blocking(OutboundQueueCapacity))
  let notifications = self.state.subscribe()
  // Readiness doubles as the resync hint: the client treats
  // `agent.connected` as "state may have changed, reload". Queue it before
  // any notification forwarder exists, making it this subscription's first
  // outbound frame even if the hub publishes immediately after subscribe.
  out.put(Notify(AgentConnected({ stage: Accepted, })))
  { out, notifications, }
}

///|
/// An inbound frame, classified for routing.
priv enum Inbound {
  // The raw `id` (echoed back verbatim), the method, and the params.
  Request(Json, String, Json)
  // Client notifications are valid JSON-RPC but this transport currently
  // has none to act on, so they are ignored without a response.
  ClientNotification
  // Not JSON at all (-32700).
  Unparsable
  // JSON, but not a JSON-RPC request (-32600).
  Invalid
  // A valid request envelope whose catalog params are not an object (-32602).
  InvalidParams(Json)
  // The bounded reader stops before parsing an oversized request.
  Oversized
}

///|
/// The client stopped draining and its outbound queue stood full; raising
/// this out of the notification pump is how the connection gets torn down.
priv suberror SlowClient {
  SlowClient(String)
}

///|
const PingIntervalMs = 30_000

///|
/// How many outbound frames may queue before writers suspend. This is also
/// the slow-client limit: a channel that stalls long enough to fill it gets
/// the connection torn down (the pump must not block on a full queue — a
/// pump parked in `put` would never get back to its subscription to notice
/// that it lagged).
const OutboundQueueCapacity = 64

///|
/// Maximum request bodies and operation tasks retained by one remote client.
/// The reader acquires before spawning, so the channel itself supplies
/// backpressure instead of creating an unbounded crowd of tasks waiting on
/// slower engine, filesystem, or registry work.
const InflightRequestCapacity = 32

///|
/// Four 5 MiB images expand to about 27 MiB in base64. Leave room for the
/// prompt and JSON envelope, while keeping a hard bound on incoming data.
const InboundFrameMaxBytes : Int = 32 * 1024 * 1024

///|
/// Enforce one outbound bound for notifications and responses. A producer
/// must never park behind a stalled channel: raising from any request task or
/// the notification pump tears down the task group and reconnects cleanly.
fn enqueue_outgoing(
  out : @async.Queue[Outgoing],
  item : Outgoing,
) -> Unit raise {
  guard out.try_put(item) else {
    raise SlowClient("client not draining outbound frames")
  }
}

///|
/// JSON-RPC error codes (docs/remote-protocol.md).
const CodeParseError = -32700

///|
const CodeInvalidRequest = -32600

///|
const CodeMethodNotFound = -32601

///|
const CodeInvalidParams = -32602

///|
const CodeInternalError = -32603

///|
const CodeEngineError = -32000

///|
const CodeHostError = -32001

///|
/// Dial and serve one announced remote client. A client hanging up mid-run
/// is routine and only retires this actor; cancelling the parent relay actor
/// still propagates so every owned resource is closed immediately.
async fn ClientActor::run(self : ClientActor, url : String) -> Unit {
  let conn = @websocket.Conn::connect(url)
  defer conn.close()
  self.serve(conn) catch {
    _ => ()
  }
}

///|
/// Serve the actor's connected channel until the peer closes it. Anything
/// else that ends the connection raises: a failed read or write, the hub
/// subscription lagging, or the outbound queue standing full.
async fn[T : ClientTransport] ClientActor::serve(
  self : ClientActor,
  transport : T,
) -> Unit {
  let subscription = self.open_subscription()
  let out = subscription.out
  let notifications = subscription.notifications
  let request_permits : @semaphore.Semaphore = Semaphore(
    InflightRequestCapacity,
    initial_value=InflightRequestCapacity,
  )
  // Endpoint closures capture this connection's watch and PTY ownership once;
  // every request only performs a name lookup in the stable catalog.
  let endpoints = @api.endpoints(self.state, self.host_connection)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      // The channel's only write boundary. Even keepalives pass through
      // here, so a transport never sees interleaved sends.
      for ;; {
        match out.get() {
          Response(envelope) => transport.send_envelope(envelope.stringify())
          Notify(notification) =>
            transport.send_envelope(
              notification_envelope(notification).stringify(),
            )
          Ping => transport.keepalive()
          RefuseOversized => {
            transport.refuse_oversized()
            group.return_immediately(())
          }
        }
      }
    })
    group.spawn_bg(() => {
      // Filesystem watch events belong to this connection. They
      // bypass the shared hub so other desktop and remote clients never
      // receive this connection's `fs.changed` notifications.
      self.host_connection.run(
        notification => enqueue_outgoing(out, Notify(notification)),
        notification => enqueue_outgoing(out, Notify(notification)),
      )
    })
    group.spawn_bg(() => {
      // Tears the connection down either way it ends — the client
      // reconnects into a resync: this subscription lagging behind the hub's
      // log (`next` raises), or the outbound queue standing full (the channel
      // has stalled for `OutboundQueueCapacity` frames, and the protocol
      // promises a disconnect over a silent gap in the stream).
      for ;; {
        let notification = notifications.next() catch {
          @broadcast.Lagged(missed~) as lagged => {
            @xlog.warn(category="transport") <?
              {
                "event": "hub_subscription_lagged",
                "transport": "remote",
                "missed": missed,
              }
            raise lagged
          }
          error => raise error
        }
        guard notification_for_client(notification) is Some(notification) else {
          continue
        }
        enqueue_outgoing(out, Notify(notification))
      }
    })
    group.spawn_bg(() => {
      for ;; {
        @async.sleep(PingIntervalMs)
        enqueue_outgoing(out, Ping)
      }
    })
    for ;; {
      guard transport.next_frame() is Some(frame) else {
        group.return_immediately(())
        return
      }
      match frame {
        Oversized => {
          // The stream is now mid-request, so nothing more can be read from
          // it; the writer ends the connection once the refusal is out.
          enqueue_outgoing(out, RefuseOversized)
          return
        }
        Request(id, method_, params) =>
          if method_ == "fs.watch" || method_ == "fs.unwatch" {
            // Watch ownership is ordered by the client's request stream. Run
            // these two operations at the reader boundary: spawning first
            // would let task scheduling enqueue a later unwatch before an
            // earlier watch (or vice versa), despite the actor's FIFO
            // mailbox. Resolution is rare and only delays later inbound
            // requests; outbound notifications and pings have their own
            // tasks.
            enqueue_outgoing(
              out,
              Response(run_request(endpoints, id, method_, params)),
            )
          } else {
            // Each other request runs in its own task so a slow op (an engine
            // start, a big file read) does not block other admitted requests;
            // acquiring before spawn bounds retained tasks and lets the
            // channel's backpressure slow a client that exceeds this connection's
            // concurrency budget. Replies are correlated by id, not order.
            request_permits.acquire()
            group.spawn_bg(() => {
              defer request_permits.release()
              enqueue_outgoing(
                out,
                Response(run_request(endpoints, id, method_, params)),
              )
            })
          }
        ClientNotification => ()
        Unparsable =>
          enqueue_outgoing(
            out,
            Response(
              error_envelope(Json::null(), CodeParseError, "unparsable frame"),
            ),
          )
        Invalid =>
          enqueue_outgoing(
            out,
            Response(
              error_envelope(
                Json::null(),
                CodeInvalidRequest,
                "not a JSON-RPC request",
              ),
            ),
          )
        InvalidParams(id) =>
          enqueue_outgoing(
            out,
            Response(
              error_envelope(
                id,
                CodeInvalidParams,
                "method parameters must be an object",
              ),
            ),
          )
      }
    }
  })
}

///|
fn notification_envelope(notification : @protocol.Notification) -> Json {
  {
    "jsonrpc": "2.0",
    "method": Json(notification.wire_name()),
    "params": notification.params(),
  }
}

///|
/// Serve one client over a byte stream, one JSON-RPC envelope per line in
/// each direction, until `input` ends. A host whose only client arrives this
/// way has nothing left to serve once this returns or raises.
pub async fn serve_lines(
  state : @api.ApiState,
  input : &@io.Reader,
  output : &@io.Writer,
) -> Unit {
  ClientActor(state).serve(LineTransport(input, output))
}

///|
fn classify(text : String) -> Inbound {
  let message = @json.parse(text) catch { _ => return Unparsable }
  guard message is Object(fields) else { return Invalid }
  // Reject protocol lookalikes before any catalog method can run.
  guard fields.get("jsonrpc") is Some("2.0") else { return Invalid }
  guard fields.get("method") is Some(String(method_)) else { return Invalid }
  let id = fields.get("id")
  // JSON-RPC request ids may only be strings, numbers, or null. They remain
  // opaque here and are echoed unchanged in the response.
  match id {
    None | Some(String(_)) | Some(Number(_, ..)) | Some(Null) => ()
    Some(_) => return Invalid
  }
  let params = match fields.get("params") {
    Some(Object(_) as params) => params
    // This catalog uses named object parameters rather than positional
    // arrays. A malformed notification still receives no response.
    Some(_) =>
      match id {
        Some(id) => return InvalidParams(id)
        None => return ClientNotification
      }
    None => Json::empty_object()
  }
  match id {
    Some(id) => Request(id, method_, params)
    None => ClientNotification
  }
}

///|
/// Retain transient lifecycle information while dropping durable transcript
/// duplicates. The original event remains available to local clients.
fn remote_lifecycle(event : @wire.Event) -> @wire.Event? {
  match event {
    ReasoningMessage(..) => Some(ReasoningMessage(content=""))
    AssistantMessage(..) => Some(AssistantMessage(content=""))
    ToolResult(..)
    | AutoCompactionFinished(..)
    | AgentFinished(..)
    | ContextYield(..) => None
    CompactionFinished(from_sequence~, to_sequence~, ..) =>
      Some(CompactionFinished(from_sequence~, to_sequence~, summary=""))
    _ => Some(event)
  }
}

///|
/// Apply the remote delivery profile at the connection's edge.
/// Full semantic transcript objects have a canonical `session.event` twin;
/// deltas, metrics, errors, acknowledgements, and lifecycle state pass
/// through. Lifecycle frames carrying large durable text are copied and
/// trimmed so the hub's original notification stays untouched for local
/// transports.
fn notification_for_client(
  notification : @protocol.Notification,
) -> @protocol.Notification? {
  match notification {
    AgentEvent(payload) => {
      // Desktop starts always name a durable session. An event without one
      // cannot be reconciled with the session transcript and is not part of
      // the supported remote profile.
      guard !payload.session.is_empty() else { return None }
      if remote_lifecycle(payload.event) is Some(event) {
        Some(AgentEvent({ ..payload, event, }))
      } else {
        None
      }
    }
    AgentStarted(payload) if !payload.session.is_empty() =>
      Some(AgentStarted(payload))
    AgentStarted(_) => None
    _ => Some(notification)
  }
}

///|
/// Run one request through the dispatcher and shape the outcome as a
/// JSON-RPC response, mapping each typed failure to its protocol code.
async fn run_request(
  endpoints : Array[@endpoint.Endpoint],
  id : Json,
  method_ : String,
  params : Json,
) -> Json {
  guard endpoints.iter().find_first(endpoint => endpoint.name() == method_)
    is Some(endpoint) else {
    return error_envelope(id, CodeMethodNotFound, "unknown method '\{method_}'")
  }
  let result = endpoint.invoke(params) catch {
    @json.JsonDecodeError(_) as error =>
      return error_envelope(id, CodeInvalidParams, "\{error}")
    @host.PayloadError(message) =>
      return error_envelope(id, CodeInvalidParams, message)
    @engine.EngineError(message) =>
      return error_envelope(id, CodeEngineError, message)
    @host.HostError(message) =>
      return error_envelope(id, CodeHostError, message)
    error =>
      return error_envelope(id, CodeInternalError, "internal error: \{error}")
  }
  { "jsonrpc": "2.0", "id": id, "result": result }
}

///|
fn error_envelope(id : Json, code : Int, message : String) -> Json {
  {
    "jsonrpc": "2.0",
    "id": id,
    "error": { "code": Json(code.to_double()), "message": message },
  }
}

///|
async test "readiness precedes the first forwarded hub notification" {
  let state = @api.ApiState(engine="unused")
  let subscription = ClientActor(state).open_subscription()
  state.publish(
    SessionEvent({
      session: "session-1",
      sequence: 1,
      event: {
        sequence: 1,
        ts: None,
        item: User({ content: Content([Text("test")]), submission_id: None, }),
      },
      session_root: "/sessions/global",
    }),
  )
  let notification = subscription.notifications.next()
  assert_true(subscription.out.try_put(Notify(notification)))
  guard subscription.out.get() is Notify(readiness) else {
    fail("expected readiness notification")
  }
  assert_eq(readiness.wire_name(), "agent.connected")
  guard subscription.out.get() is Notify(forwarded) else {
    fail("expected forwarded notification")
  }
  assert_eq(forwarded.wire_name(), "session.event")
}

///|
test "a full outbound queue rejects responses instead of blocking tasks" {
  let out : @async.Queue[Outgoing] = Queue(kind=Blocking(1))
  enqueue_outgoing(out, Response(Json::null()))
  try enqueue_outgoing(out, Response(Json::null())) catch {
    SlowClient(_) => ()
    error => raise error
  } noraise {
    _ => fail("a full outbound queue accepted another response")
  }
}

///|
test "classify accepts client notifications" {
  let message : Json = {
    "jsonrpc": "2.0",
    "method": "client.notice",
    "params": { "value": true },
  }
  match classify(message.stringify()) {
    ClientNotification => ()
    _ => fail("expected a client notification")
  }
}

///|
test "classify enforces the JSON-RPC 2.0 request envelope" {
  for
    message in [
      Json({ "id": Json(1), "method": Json("session.list") }),
      { "jsonrpc": "1.0", "id": 1, "method": "session.list" },
      { "jsonrpc": "2.0", "id": true, "method": "session.list" },
      { "jsonrpc": "2.0", "id": {}, "method": "session.list" },
      { "jsonrpc": "2.0", "id": [], "method": "session.list" },
    ] {
    assert_true(classify(message.stringify()) is Invalid)
  }
  for id in [Json("request-1"), Json(1), Json::null()] {
    let message : Json = {
      "jsonrpc": "2.0",
      "id": id,
      "method": "session.list",
    }
    match classify(message.stringify()) {
      Request(actual_id, method_, Object(params)) => {
        assert_eq(actual_id, id)
        assert_eq(method_, "session.list")
        assert_eq(params.length(), 0)
      }
      _ => fail("expected a valid request")
    }
  }
}

///|
test "classify rejects non-object catalog parameters" {
  let request : Json = {
    "jsonrpc": "2.0",
    "id": "request-1",
    "method": "update.apply",
    "params": [],
  }
  match classify(request.stringify()) {
    InvalidParams(id) => assert_eq(id, Json("request-1"))
    _ => fail("expected invalid method parameters")
  }
  let notification : Json = {
    "jsonrpc": "2.0",
    "method": "client.notice",
    "params": [],
  }
  // Notifications never receive responses, including when this catalog
  // cannot consume their parameters.
  assert_true(classify(notification.stringify()) is ClientNotification)
}

///|
test "remote delivery drops notifications without a session" {
  let started_notification : @protocol.Notification = AgentStarted({
    run_id: "run-ephemeral",
    submission_id: None,
    engine: None,
    model: None,
    max_steps: None,
    session: "",
    session_root: None,
  })
  assert_true(notification_for_client(started_notification) is None)
  let event : @protocol.AgentEventPayload = {
    run_id: None,
    session: "",
    event: ToolResult(
      tool_call_id="call-1",
      tool_name="read",
      is_error=false,
      content="ephemeral result",
      brief=None,
    ),
  }
  let notification : @protocol.Notification = AgentEvent({ ..event, })
  assert_true(notification_for_client(notification) is None)
}
