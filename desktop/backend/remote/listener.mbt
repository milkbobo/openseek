// The protocol on a loopback port, for a host with no window: one WebSocket
// route carrying the JSON-RPC connection a relayed browser gets
// (docs/remote-protocol.md), and nothing else — no page, no account routes.
// Its client is a program, not a browser: the desktop application, reaching
// this machine through a forwarded port.
//
// Loopback limits who can reach the port, not who they are. Two kinds of
// caller must not get a command channel by reaching it:
//
// - A web page. Any page the user has open can dial loopback, and a browser
//   always says where the dialling page came from. No browser is a client
//   here, so a request that carries `Origin` at all is refused.
// - Another account on the machine, or whoever a published or forwarded port
//   lets in. Only a secret tells them from the user: the token minted when
//   the port is bound, which every request must present.

///|
/// The loopback listener a headless host serves the protocol on.
pub struct Listener {
  server : @http.Server
  token : String
}

///|
/// The one route: the JSON-RPC connection, upgraded to a WebSocket.
pub const ListenerSocketPath = "/v1/ws"

///|
/// Bind `127.0.0.1:port`; port 0 asks the system for a free one. A taken
/// port is an error rather than a quiet move to another: whoever chose the
/// number has usually forwarded it already.
pub async fn Listener::bind(port~ : Int) -> Listener {
  guard @entropy.random_hex(32) is Some(token) else {
    // No OS entropy is a hard failure, never weak randomness.
    raise @host.HostError("no OS entropy available for the listener token")
  }
  let server = @http.Server(
    @socket.Addr::parse("127.0.0.1:\{port}"),
    reuse_addr=true,
  )
  { server, token, }
}

///|
/// The port that was bound, which differs from the one asked for when that
/// was 0.
pub fn Listener::port(self : Listener) -> Int {
  self.server.addr.port()
}

///|
/// The secret a client presents as `Authorization: Bearer <token>`. The host
/// hands it to whoever started it and to no one else.
pub fn Listener::token(self : Listener) -> String {
  self.token
}

///|
/// Accept and serve clients until cancelled. Each connection is its own
/// task and its own client actor; any number may be connected at once, and a
/// client that goes away takes nothing with it but its own subscription.
pub async fn Listener::run(self : Listener, state : @api.ApiState) -> Unit {
  defer self.server.close()
  @async.with_task_group(group => {
    for ;; {
      let (conn, _) = self.server.accept()
      group.spawn_bg(allow_failure=true, () => self.handle(state, conn))
    }
  })
}

///|
/// What a request is owed.
priv enum Admission {
  Admitted
  // Carries the status line to answer with.
  Refused(Int, String)
} derive(Eq, Debug)

///|
/// Decide one request from its request line and the three headers that
/// matter, each absent when the request did not send it. The order is the
/// order of what a refusal may reveal: a web page and a caller without the
/// token learn nothing about the routes.
fn admission(
  meth : @http.RequestMethod,
  path : String,
  token~ : String,
  origin? : String,
  authorization? : String,
  upgrade? : String,
) -> Admission {
  guard origin is None else { return Refused(403, "Forbidden") }
  guard authorization == Some("Bearer \{token}") else {
    return Refused(401, "Unauthorized")
  }
  guard path == ListenerSocketPath else { return Refused(404, "Not Found") }
  guard meth is Get else { return Refused(405, "Method Not Allowed") }
  guard upgrade is Some(upgrade) && upgrade.to_lower() == "websocket" else {
    return Refused(400, "Bad Request")
  }
  Admitted
}

///|
async fn Listener::handle(
  self : Listener,
  state : @api.ApiState,
  conn : @http.ServerConnection,
) -> Unit {
  defer conn.close()
  let request = conn.read_request()
  match
    admission(
      request.meth,
      request.path,
      token=self.token,
      origin?=request.headers.get("origin"),
      authorization?=request.headers.get("authorization"),
      upgrade?=request.headers.get("upgrade"),
    ) {
    Admitted => serve_ws(state, request, conn)
    Refused(code, reason) => respond_status(conn, code, reason)
  }
}

///|
test "the listener refuses every request that names an origin" {
  // A browser always names the page that dialled; the right token does not
  // make a web page a client.
  let forbidden : Admission = Refused(403, "Forbidden")
  let origins = [
    "https://example.com",
    // Not even this host's own origin: no page is served from it.
     "http://127.0.0.1:27184",
    // What a page opened from a file, or a sandboxed frame, sends.
     "null",
  ]
  for origin in origins {
    assert_eq(
      admission(
        Get,
        ListenerSocketPath,
        token="sesame",
        origin~,
        authorization="Bearer sesame",
        upgrade="websocket",
      ),
      forbidden,
    )
  }
}

///|
test "the listener admits only the bearer of its token" {
  let unauthorized : Admission = Refused(401, "Unauthorized")
  assert_eq(
    admission(Get, ListenerSocketPath, token="sesame", upgrade="websocket"),
    unauthorized,
  )
  for authorization in ["Bearer other", "sesame", "Bearer ", "bearer sesame"] {
    assert_eq(
      admission(
        Get,
        ListenerSocketPath,
        token="sesame",
        authorization~,
        upgrade="websocket",
      ),
      unauthorized,
    )
  }
  assert_eq(
    admission(
      Get,
      ListenerSocketPath,
      token="sesame",
      authorization="Bearer sesame",
      upgrade="WebSocket",
    ),
    Admitted,
  )
}

///|
test "a caller without the token learns nothing about the routes" {
  // The same answer for the socket and for a path that does not exist.
  for path in [ListenerSocketPath, "/", "/v1/devices"] {
    assert_eq(
      admission(Get, path, token="sesame"),
      Refused(401, "Unauthorized"),
    )
  }
}

///|
test "with the token, only an upgrade of the socket route is served" {
  let authorization = "Bearer sesame"
  assert_eq(
    admission(Get, "/", token="sesame", authorization~, upgrade="websocket"),
    Refused(404, "Not Found"),
  )
  assert_eq(
    admission(
      Post,
      ListenerSocketPath,
      token="sesame",
      authorization~,
      upgrade="websocket",
    ),
    Refused(405, "Method Not Allowed"),
  )
  assert_eq(
    admission(Get, ListenerSocketPath, token="sesame", authorization~),
    Refused(400, "Bad Request"),
  )
}

///|
/// The whole path once, over a real socket: the token opens the connection a
/// relayed browser gets — readiness first, then answers — and a dialler
/// without it, or one that names an origin, gets no socket at all.
async test "a client with the token is served the protocol on loopback" {
  let listener = Listener::bind(port=0)
  let state = @api.ApiState(engine="unused")
  let url = "ws://127.0.0.1:\{listener.port()}\{ListenerSocketPath}"
  let authorization = "Bearer \{listener.token()}"
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => listener.run(state))
    let turned_away : Array[Map[@http.CaseInsensitiveString, String]] = [
      {},
      { "Authorization": authorization, "Origin": "https://example.com" },
    ]
    for headers in turned_away {
      let refused = try {
        @websocket.Conn::connect(url, headers~).close()
        false
      } catch {
        _ => true
      }
      assert_true(refused)
    }
    let conn = @websocket.Conn::connect(url, headers={
      "Authorization": authorization,
    })
    defer conn.close()
    guard @json.parse(conn.recv().read_all().text())
      is { "method": method_, .. } else {
      fail("the first message is not a notification")
    }
    assert_eq(method_, "agent.connected")
    conn.send_text(
      "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"no.such.method\"}",
    )
    guard @json.parse(conn.recv().read_all().text())
      is { "id": 7, "error": { "code": code, .. }, .. } else {
      fail("the request was not answered with an error")
    }
    assert_eq(code, Json(CodeMethodNotFound.to_double()))
  })
}
