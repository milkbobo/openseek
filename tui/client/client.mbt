///|
/// A failed shared-server operation or connection. JSON-RPC errors retain
/// their server code and data so callers can apply each command's contract.
pub(all) suberror ClientError {
  Closed(String)
  Protocol(String)
  Rpc(code~ : Int32, message~ : String, data~ : Json?)
} derive(Debug)

///|
pub extend ClientError with @debug.Debug::{to_repr}

///|
/// A native authenticated JSON-RPC channel to the shared SeekMoon backend.
/// Run its receive pump for the lifetime of all requests and notifications.
struct Client {
  socket : @websocket.Conn
  writer : @async.Mutex
  pending : Map[Int32, @async.Queue[Json]]
  notifications : @async.Queue[@protocol.Notification]
  mut next_id : Int32
  mut closed : Error?
  mut running : Bool
}

///|
/// Connect to a server's WebSocket URL with its launch token. A native client
/// sends the same session capability as the browser and has no web Origin.
pub async fn Client::connect(url : String, token~ : String) -> Client {
  guard !token.is_empty() && !token.contains("\r") && !token.contains("\n") else {
    raise ClientError::Protocol("a server launch token is required")
  }
  let port = server_port(url)
  let socket = @websocket.Conn::connect(url, headers={
    "Cookie": "seekmoon_session_\{port}=\{token}",
  })
  {
    socket,
    writer: @async.Mutex(),
    pending: {},
    notifications: @async.Queue(kind=Blocking(4096)),
    next_id: 1,
    closed: None,
    running: false,
  }
}

///|
/// Stop the socket and wake every suspended request or notification consumer.
pub fn Client::close(self : Client) -> Unit {
  self.finish(ClientError::Closed("server connection closed"))
}

///|
fn Client::finish(self : Client, error : Error) -> Unit {
  if self.closed is Some(_) {
    return
  }
  self.closed = Some(error)
  self.socket.close()
  self.notifications.close(error~, clear=true)
  for _, reply in self.pending {
    reply.close(error~, clear=true)
  }
  self.pending.clear()
}

///|
/// Read and correlate responses while preserving the server notification
/// order. A stalled consumer closes the channel so callers can resynchronize.
pub async fn Client::run(self : Client) -> Unit {
  guard !self.running else {
    raise ClientError::Protocol("the client receive pump is already running")
  }
  self.running = true
  defer self.close()
  for ;; {
    let message = self.socket.recv()
    guard message.kind is Text else {
      raise ClientError::Protocol("the server sent a binary JSON-RPC frame")
    }
    self.dispatch(@json.parse(message.read_all().text()))
  }
}

///|
fn Client::dispatch(self : Client, envelope : Json) -> Unit raise {
  guard envelope is Object(fields) && fields.get("jsonrpc") is Some("2.0") else {
    raise ClientError::Protocol("invalid JSON-RPC response envelope")
  }
  if fields.get("id") is Some(id) {
    let id : Int32 = @json.from_json(id)
    if self.pending.get(id) is Some(reply) {
      guard reply.try_put(envelope) else {
        raise ClientError::Protocol("the server replied to one request twice")
      }
    }
    return
  }
  guard fields.get("method") is Some(String(method_)) else {
    raise ClientError::Protocol("JSON-RPC notification has no method")
  }
  if @protocol.Notification::from_wire(
      method_,
      fields.get("params").unwrap_or(Json::empty_object()),
    )
    is Some(notification) {
    guard self.notifications.try_put(notification) else {
      raise ClientError::Closed(
        "notification consumer fell behind; reconnect to resynchronize",
      )
    }
  }
}

///|
/// Receive the next typed server event. Shutdown raises instead of leaving a
/// detached consumer waiting forever.
pub async fn Client::receive(self : Client) -> @protocol.Notification {
  self.notifications.get()
}

///|
/// Invoke a catalog operation with a raw JSON object. Requests can overlap;
/// the single socket writer and response ids keep their frames independent.
pub async fn Client::invoke(
  self : Client,
  method_ : String,
  params : Json,
) -> Json {
  if self.closed is Some(error) {
    raise error
  }
  let id = self.next_id
  self.next_id += 1
  let reply : @async.Queue[Json] = Queue(kind=Blocking(1))
  self.pending[id] = reply
  defer self.pending.remove(id)
  {
    self.writer.acquire()
    defer self.writer.release()
    if self.closed is Some(error) {
      raise error
    }
    let request : Json = {
      "jsonrpc": "2.0",
      "id": id,
      "method": method_,
      "params": params,
    }
    self.socket.send_text(request.stringify())
  }
  decode_reply(reply.get())
}

///|
/// Invoke a command using the desktop's shared request and reply types.
pub async fn[Payload : ToJson, Reply : @json.FromJson] Client::call(
  self : Client,
  command : @commands.Command[Payload, Reply],
  payload : Payload,
) -> Reply {
  @json.from_json(self.invoke(command.name(), payload.to_json()))
}

///|
fn decode_reply(envelope : Json) -> Json raise {
  guard envelope is Object(fields) else {
    raise ClientError::Protocol("invalid JSON-RPC reply")
  }
  match (fields.get("result"), fields.get("error")) {
    (Some(result), None) => result
    (None, Some(Object(error))) => {
      guard error.get("code") is Some(code) &&
        error.get("message") is Some(String(message)) else {
        raise ClientError::Protocol("invalid JSON-RPC error")
      }
      raise ClientError::Rpc(
        code=@json.from_json(code),
        message~,
        data=error.get("data"),
      )
    }
    _ =>
      raise ClientError::Protocol(
        "JSON-RPC reply must contain one result or error",
      )
  }
}

///|
fn server_port(url : String) -> Int32 raise ClientError {
  let authority = if url.strip_prefix("ws://") is Some(rest) {
    rest
  } else if url.strip_prefix("wss://") is Some(rest) {
    rest
  } else {
    raise ClientError::Protocol("server URL must use ws:// or wss://")
  }
  let authority = authority.split("/").next().unwrap_or("")
  guard !authority.contains("@") && !authority.is_empty() else {
    raise ClientError::Protocol("invalid server authority")
  }
  if authority.rev_find(":") is Some(index) {
    let port = @string.parse_int(authority[index + 1:]) catch {
      _ => raise ClientError::Protocol("invalid server port")
    }
    guard port >= 1 && port <= 65535 else {
      raise ClientError::Protocol("invalid server port")
    }
    port
  } else if url.has_prefix("wss://") {
    443
  } else {
    80
  }
}
