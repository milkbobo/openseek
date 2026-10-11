///|
/// A line transport reading what `write` produces and discarding its output.
fn reading(
  write : async (&@io.Writer) -> Unit,
) -> (LineTransport, @io.MemoryReader) {
  let reader = @io.MemoryReader(write)
  let (_, output) = @io.pipe()
  (LineTransport(reader, output), reader)
}

///|
async test "lines split wherever the stream happens to break them" {
  let (transport, reader) = reading(writer => {
    writer.write(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"meth")
    writer.write(b"od\":\"session.list\"}\n{\"jsonrpc\":\"2.0\",")
    writer.write(
      b"\"id\":2,\"method\":\"fs.watch\",\"params\":{\"path\":\"/w\"}}\n",
    )
  })
  defer reader.close()
  guard ClientTransport::next_frame(transport)
    is Some(Request(first, "session.list", _)) else {
    fail("expected the first request")
  }
  assert_eq(first, Json::number(1))
  guard ClientTransport::next_frame(transport)
    is Some(Request(second, "fs.watch", params)) else {
    fail("expected the second request")
  }
  assert_eq(second, Json::number(2))
  assert_eq(params, { "path": "/w" })
  assert_true(ClientTransport::next_frame(transport) is None)
}

///|
async test "a line that is not a request is answered, not fatal" {
  let (transport, reader) = reading(writer => {
    writer.write(
      b"not json\n{\"jsonrpc\":\"2.0\",\"method\":\"client.notice\"}\n",
    )
  })
  defer reader.close()
  assert_true(ClientTransport::next_frame(transport) is Some(Unparsable))
  assert_true(
    ClientTransport::next_frame(transport) is Some(ClientNotification),
  )
}

///|
async test "the input ending mid-line is the peer hanging up" {
  let (transport, reader) = reading(writer => {
    writer.write(b"{\"jsonrpc\":\"2.0\",\"id\":1,")
  })
  defer reader.close()
  assert_true(ClientTransport::next_frame(transport) is None)
}

///|
async test "a line at the size limit is read and one byte more is refused" {
  let request = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session.list\"}"
  let padding = b" ".repeat(65536)
  async fn write_line(writer : &@io.Writer, length : Int) -> Unit {
    writer.write(request)
    for remaining = length - request.length(); remaining > 0; {
      let count = Int::min(remaining, padding.length())
      writer.write(padding[:count])
      continue remaining - count
    }
    writer.write(b"\n")
  }

  let (transport, reader) = reading(writer => {
    write_line(writer, InboundFrameMaxBytes)
  })
  defer reader.close()
  assert_true(
    ClientTransport::next_frame(transport)
    is Some(Request(_, "session.list", _)),
  )
  let mut written = 0
  let (transport, reader) = reading(writer => {
    writer.write(request)
    written += request.length()
    while written < InboundFrameMaxBytes {
      let count = Int::min(InboundFrameMaxBytes - written, padding.length())
      writer.write(padding[:count])
      written += count
    }
    writer.write(b"x")
    // The reader must refuse before waiting for the rest of the line.
    @async.sleep(60_000)
  })
  defer reader.close()
  assert_true(ClientTransport::next_frame(transport) is Some(Oversized))
  assert_eq(written, InboundFrameMaxBytes)
}

///|
async test "a client on a byte stream is greeted, answered, and let go" {
  let state = @api.ApiState(engine="unused")
  let (requests, to_host) = @io.pipe()
  let (from_host, replies) = @io.pipe()
  @async.with_task_group(group => {
    group.spawn_bg(() => serve_lines(state, requests, replies))
    // Readiness is the stream's first line, before any request is sent.
    guard from_host.read_until("\n") is Some(greeting) else {
      fail("the host closed the stream before greeting")
    }
    assert_eq(@json.parse(greeting), {
      "jsonrpc": "2.0",
      "method": "agent.connected",
      "params": { "stage": "accepted" },
    })
    to_host.write(
      "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"no.such.method\"}\n",
    )
    guard from_host.read_until("\n") is Some(reply) else {
      fail("the host closed the stream before replying")
    }
    assert_eq(@json.parse(reply), {
      "jsonrpc": "2.0",
      "id": 7,
      "error": { "code": -32601, "message": "unknown method 'no.such.method'" },
    })
    // Closing the client's end is what ends the connection; `serve_lines`
    // returning lets the group finish.
    to_host.close()
  })
}
