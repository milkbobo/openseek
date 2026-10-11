// What a client connection needs from the channel carrying it. The actor in
// `serve.mbt` speaks JSON-RPC envelopes and knows nothing below them; a
// transport moves one envelope at a time and owns how its channel frames
// them, keeps itself alive, and refuses what it will not carry.

///|
priv trait ClientTransport {
  // The next inbound frame, classified, or `None` once the peer has closed
  // the channel. Only the connection's reader calls this.
  async fn next_frame(Self) -> Inbound?
  // Send one JSON-RPC envelope. Only the connection's writer calls this and
  // the two methods below, so a transport never sees interleaved sends.
  async fn send_envelope(Self, String) -> Unit
  async fn keepalive(Self) -> Unit
  // Tell the peer its last request was over the size limit. The connection
  // ends right after: the reader stopped in the middle of that request.
  async fn refuse_oversized(Self) -> Unit
}

///|
const OversizedReason = "JSON-RPC request exceeds 32 MiB"

///|
/// A WebSocket carries one envelope per text message.
impl ClientTransport for @websocket.Conn with fn next_frame(self) {
  for ;; {
    let message = self.recv() catch {
      @websocket.ConnectionClosed(_, _) => return None
      error => raise error
    }
    // The protocol is JSON text; a binary frame is a peer bug.
    guard message.kind is Text else { continue }
    return Some(Inbound::read(message))
  }
}

///|
impl ClientTransport for @websocket.Conn with fn send_envelope(self, envelope) {
  self.send_text(envelope)
}

///|
/// Protocol-level keepalive: a dead middlebox connection surfaces as a failed
/// ping write instead of lingering forever.
impl ClientTransport for @websocket.Conn with fn keepalive(self) {
  self.ping()
}

///|
impl ClientTransport for @websocket.Conn with fn refuse_oversized(self) {
  self.send_close(code=MessageTooBig, reason=OversizedReason)
}

///|
/// A byte stream carries one envelope per line in each direction: a pipe, a
/// process's standard streams, whatever `ssh` or `docker exec -i` hands over.
/// JSON text never holds a raw line feed, so the line feed is the frame.
priv struct LineTransport {
  input : &@io.Reader
  output : &@io.Writer
  // What was read past the end of the last returned line.
  mut carry : BytesView
}

///|
fn LineTransport::LineTransport(
  input : &@io.Reader,
  output : &@io.Writer,
) -> LineTransport {
  { input, output, carry: b"", }
}

///|
extend LineTransport with ClientTransport::{send_envelope}

///|
/// Read up to the next line feed, growing only as bytes arrive and stopping
/// at the first byte over the limit rather than buffering an endless line.
impl ClientTransport for LineTransport with fn next_frame(self) {
  let line = Buffer()
  for ;; {
    let chunk = if self.carry.length() > 0 {
      self.carry
    } else {
      // The input ending is how this peer hangs up; a line it never
      // finished is not a request.
      guard self.input.read_some(max_len=65536) is Some(chunk) else {
        return None
      }
      chunk
    }
    match chunk.find(b"\n") {
      Some(end) => {
        self.carry = chunk[end + 1:]
        if end > InboundFrameMaxBytes - line.length() {
          return Some(Oversized)
        }
        line.write_bytes(chunk[:end])
        return Some(classify(@utf8.decode(line.to_bytes())))
      }
      None => {
        self.carry = b""
        if chunk.length() > InboundFrameMaxBytes - line.length() {
          return Some(Oversized)
        }
        line.write_bytes(chunk)
      }
    }
  }
}

///|
impl ClientTransport for LineTransport with fn send_envelope(self, envelope) {
  // One write per line; the connection's single writer keeps lines whole.
  self.output.write("\{envelope}\n")
}

///|
/// A byte stream has no frame that is not a message, and needs none: the
/// other end going away closes the stream, which the reader sees at once.
impl ClientTransport for LineTransport with fn keepalive(_) {

}

///|
/// A stream has no close frame to carry the reason, so it travels as the
/// error of a request whose id was never read.
impl ClientTransport for LineTransport with fn refuse_oversized(self) {
  self.send_envelope(
    error_envelope(Json::null(), CodeInvalidRequest, OversizedReason).stringify(),
  )
}
