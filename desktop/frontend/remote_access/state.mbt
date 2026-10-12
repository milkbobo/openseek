// The host's relay sign-in: `auth.status` seeds the mirror at bridge time,
// `auth.connect`/`auth.disconnect` drive it from the Settings page, and the
// `auth.changed` broadcast keeps it fresh. Desktop-window ops by convention —
// a browser signs in with the relay directly — so every call here is pinned
// to the `Local` channel: the section describes this host's own relay
// registration, never a focused remote device's.

///|
/// One `auth.status`/`auth.changed` payload, decoded: who this host is
/// signed in as and whether its relay registration is live. A mirror of
/// the wire shape (docs/remote-protocol.md `auth.*`) — signed out is
/// `user_login: None`.
pub struct Status {
  server_url : String?
  connected : Bool
  managed_by_env : Bool
  user_login : String?
  device_name : String?
  device_url : String?
} derive(Eq)

///|
pub extend Status with Eq::{equal, not_equal}

///|
/// Project the shared auth status used by both replies and broadcasts.
fn Status::from_payload(payload : @protocol.AuthStatusPayload) -> Status {
  let user_login = payload.user.map(user => user.login)
  let (device_name, device_url) = match payload.device {
    Some(device) => (Some(device.name), Some(device.url))
    None => (None, None)
  }
  {
    server_url: payload.server_url,
    connected: payload.connected,
    managed_by_env: payload.managed_by_env.unwrap_or(false),
    user_login,
    device_name,
    device_url,
  }
}

///|
pub struct State {
  // The host's relay sign-in mirror, None until the first reply.
  status : Status?
  // An `auth.connect` waiting on the user's browser round-trip.
  connecting : Bool
  // The last connect/disconnect failure, shown inside the section.
  error : String?
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
pub fn State::empty() -> State {
  { status: None, connecting: false, error: None, }
}

///|
pub(all) enum Msg {
  // An `auth.status` reply or `auth.changed` broadcast: the host's relay
  // sign-in state moved.
  StatusLoaded(@protocol.AuthStatusPayload)
  // The Connect button; the flow blocks on a browser round-trip, so the
  // section shows an in-progress state until a finished/failed message
  // settles it.
  ConnectClicked
  ConnectFinished(@protocol.AuthStatusPayload)
  ConnectFailed(String)
  // The Cancel beside a waiting Connect: fires `auth.cancel`; the pending
  // connect settles the section through its own failure reply.
  CancelClicked
  // The Disconnect button and its failure (success arrives as
  // `StatusLoaded` via the op's reply).
  DisconnectClicked
  DisconnectFailed(String)
}

///|
pub fn update(
  state : State,
  msg : Msg,
  emit : @cmd.Emit[Msg],
) -> (State, @cmd.Cmd) {
  match msg {
    StatusLoaded(payload) =>
      ({ ..state, status: Some(Status::from_payload(payload)), }, @cmd.none)
    ConnectClicked =>
      // The flow blocks on a browser round-trip; a second click while one
      // is pending would start a second loopback flow just to be refused.
      if state.connecting {
        (state, @cmd.none)
      } else {
        ({ ..state, connecting: true, error: None, }, connect(emit))
      }
    ConnectFinished(payload) =>
      (
        {
          status: Some(Status::from_payload(payload)),
          connecting: false,
          error: None,
        },
        @cmd.none,
      )
    ConnectFailed(message) =>
      ({ ..state, connecting: false, error: Some(message), }, @cmd.none)
    CancelClicked =>
      // Fire-and-forget: the connect that is being cancelled reports back
      // through its own reply, which is what clears the pending state.
      (state, cancel(emit))
    DisconnectClicked => ({ ..state, error: None, }, disconnect(emit))
    DisconnectFailed(message) => ({ ..state, error: Some(message), }, @cmd.none)
  }
}
