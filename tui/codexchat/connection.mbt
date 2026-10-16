///|
/// Server-owned generations and live turn ownership belong to one connection
/// epoch. Keep durable display items until an authoritative thread read repairs
/// them, but never steer a turn that may have ended while disconnected.
pub fn State::begin_connection(self : State) -> Unit {
  self.requests = []
  self.request_generation = -1
  self.revisions.clear()
  for id, thread in self.threads {
    self.threads[id] = { ..thread, turn_id: None, status: "reconnecting", }
  }
}
