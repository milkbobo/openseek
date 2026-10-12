// The Settings page's MCP panel: which servers the user's MCP configuration
// lists and what connecting to each one yields. The host has no standing
// connections to report on — every conversation's engine connects its own —
// so the panel asks the host to check, and shows the answer until asked again.

///|
pub(all) enum Msg {
  /// The Settings page opened on this host: check unless this host's answer
  /// is already on screen.
  Opened(@interop.ChannelId)
  /// The user asked for a fresh check of the host the panel is showing.
  Refresh(@interop.ChannelId)
  /// The host answered check number `serial`.
  Checked(serial~ : Int32, Result[@protocol.McpStatusReply, String])
}

///|
/// What the panel has to show for its host.
pub enum Phase {
  /// Nothing has been asked yet.
  Unchecked
  /// A check is running; its answer is `Checked` with the state's serial.
  Checking
  /// The host answered.
  Loaded(@protocol.McpStatusReply)
  /// The check itself failed — the host could not be asked, or its engine
  /// could not run it. Distinct from a configuration the engine rejects,
  /// which is an answer.
  CheckFailed(String)
} derive(Eq)

///|
pub extend Phase with Eq::{equal, not_equal}

///|
pub struct State {
  /// The host the phase describes; `None` until Settings first opens.
  host : @interop.ChannelId?
  phase : Phase
  /// Counts checks, so the answer to a superseded one is recognized and
  /// dropped instead of overwriting its successor's.
  serial : Int32
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
pub fn State::initial() -> State {
  { host: None, phase: Unchecked, serial: 0, }
}

///|
/// What there is to show for `host`. An answer belongs to the host that gave
/// it: while another host is focused, nothing has been asked of it yet.
pub fn State::phase_for(self : State, host : @interop.ChannelId) -> Phase {
  if self.host == Some(host) {
    self.phase
  } else {
    Unchecked
  }
}

///|
pub fn update(
  emit : @cmd.Emit[Msg],
  msg : Msg,
  state : State,
) -> (@cmd.Cmd, State) {
  match msg {
    Opened(host) =>
      // Reopening Settings does not start the user's servers again: one
      // answer per host stands until Refresh.
      if state.host == Some(host) && !(state.phase is Unchecked) {
        (@cmd.none, state)
      } else {
        check(emit, host, state)
      }
    Refresh(host) =>
      // One check at a time per host; a different host's supersedes it.
      if state.host == Some(host) && state.phase is Checking {
        (@cmd.none, state)
      } else {
        check(emit, host, state)
      }
    Checked(serial~, result) => {
      guard serial == state.serial && state.phase is Checking else {
        return (@cmd.none, state)
      }
      let phase = match result {
        Ok(reply) => Loaded(reply)
        Err(message) => CheckFailed(message)
      }
      (@cmd.none, { ..state, phase, })
    }
  }
}

///|
fn check(
  emit : @cmd.Emit[Msg],
  host : @interop.ChannelId,
  state : State,
) -> (@cmd.Cmd, State) {
  let serial = state.serial + 1
  let cmd = @cmd.attempt(
    result => emit(Checked(serial~, result.map_err(@interop.bridge_error_text))),
    () => {
      @interop.bridge_request(
        host,
        @commands.mcp_status,
        @protocol.EmptyPayload::NoPayload,
      )
    },
  )
  (cmd, { host: Some(host), phase: Checking, serial, })
}
