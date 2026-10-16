///|
test "server cookies follow the socket port" {
  assert_eq(server_port("ws://127.0.0.1:27184/v1/devices/host/ws"), 27184)
  assert_eq(server_port("wss://example.com/v1/devices/host/ws"), 443)
  assert_eq(server_port("ws://localhost/socket"), 80)
  for
    url in [
      "http://localhost", "ws://localhost:0/socket", "ws://user@localhost:80/",
    ] {
    try server_port(url) catch {
      ClientError::Protocol(_) => ()
      error => raise error
    } noraise {
      _ => fail("invalid socket URL was accepted")
    }
  }
}

///|
test "JSON-RPC preserves command error codes and data" {
  let details : Json = { "retry": true }
  try
    decode_reply({
      "jsonrpc": "2.0",
      "id": 1,
      "error": {
        "code": -32001,
        "message": "workspace missing",
        "data": details,
      },
    })
  catch {
    ClientError::Rpc(code~, message~, data~) => {
      assert_eq(code, -32001)
      assert_eq(message, "workspace missing")
      assert_eq(data, Some(details))
    }
    error => raise error
  } noraise {
    _ => fail("server error became a successful reply")
  }
  assert_eq(decode_reply({ "result": Json::null() }), Json::null())
}

///|
async test "native client correlates overlapping replies and delivers typed notifications" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let port = server.addr.port()
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        let (connection, _) = server.accept()
        defer connection.close()
        let request = connection.read_request()
        assert_eq(
          request.headers.get("cookie"),
          Some("seekmoon_session_\{port}=secret"),
        )
        assert_true(request.headers.get("origin") is None)
        let socket = @websocket.Conn::from_http_server(request, connection)
        defer socket.close()
        socket.send_text(
          (
            {
              "jsonrpc": "2.0",
              "method": "agent.connected",
              "params": { "stage": "accepted" },
            } : Json).stringify(),
        )
        let first = @json.parse(socket.recv().read_all().text())
        let second = @json.parse(socket.recv().read_all().text())
        guard first is Object(first) && second is Object(second) else {
          fail("expected two request envelopes")
        }
        for request in [second, first] {
          guard request.get("id") is Some(id) &&
            request.get("method") is Some(method_) else {
            fail("request has no id or method")
          }
          socket.send_text(
            ({ "jsonrpc": "2.0", "id": id, "result": method_ } : Json).stringify(),
          )
        }
        let request = @json.parse(socket.recv().read_all().text())
        guard request is Object(fields) && fields.get("id") is Some(id) else {
          fail("expected typed command request")
        }
        assert_eq(fields.get("method"), Some(Json("fs.unwatch")))
        socket.send_text(
          ({ "jsonrpc": "2.0", "id": id, "result": {} } : Json).stringify(),
        )
        // Keep the peer alive until the client explicitly shuts down.
        ignore(socket.recv())
      })
      let client = Client::connect(
        "ws://127.0.0.1:\{port}/v1/devices/host/ws",
        token="secret",
      )
      defer client.close()
      group.spawn_bg(allow_failure=true, () => client.run())
      let first = group.spawn(() => client.invoke("one", {}))
      let second = group.spawn(() => client.invoke("two", {}))
      assert_eq(first.wait(), Json("one"))
      assert_eq(second.wait(), Json("two"))
      assert_true(client.receive() is AgentConnected({ stage: Accepted, }))
      let reply = client.call(@commands.fs_unwatch, @protocol.NoPayload)
      assert_true(reply is Acknowledged)
      client.close()
      try client.receive() catch {
        ClientError::Closed(_) => ()
        error => raise error
      } noraise {
        _ => fail("a closed notification channel did not raise")
      }
      group.return_immediately(())
    })
  })
}
