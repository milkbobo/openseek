// A conversation's changes: the pull requests and branches its agent
// attached to it, shown in the conversation overview's changes card beside
// the checkout the conversation works in. The host keeps the attached list
// beside the transcript and says only that it changed, never what it now
// holds, so the overview asks for the list whenever it comes on screen for a
// conversation, again each time the host says that conversation's list
// changed, and again when that device reconnects, since a change announced
// while the connection was down is not replayed. The user can take an
// attached item off the list; that removes the association only — it closes
// no pull request and deletes no branch.

///|
pub(all) enum Msg {
  /// The overview came on screen for this conversation.
  Opened(@interop.ConversationKey)
  /// The host saved a new list for this conversation, or may have while it
  /// was unreachable: whatever the overview holds for it is out of date.
  Changed(@interop.ConversationKey)
  /// The host answered list question number `serial`.
  Listed(serial~ : Int32, Result[@protocol.SessionArtifacts, String])
  /// The user asked to take `artifact` off the conversation's list.
  Remove(@interop.ConversationKey, @protocol.SessionArtifact)
  /// The host answered the removal of `artifact` with the list that remains.
  Removed(
    @interop.ConversationKey,
    @protocol.SessionArtifact,
    Result[@protocol.SessionArtifacts, String]
  )
}

///|
/// What the overview has of its conversation's attached list.
pub enum Phase {
  /// Nothing has been asked yet.
  Unchecked
  /// A question is out; its answer is `Listed` with the state's serial.
  Checking
  /// The host answered.
  Loaded(Array[@protocol.SessionArtifact])
  /// The host answered, and the question is out again. The last answer stays
  /// up until its replacement arrives, so the overview coming back or another
  /// client's change does not blank the list.
  Reloading(Array[@protocol.SessionArtifact])
  /// The question itself failed: the host could not be reached or could not
  /// read the saved list.
  CheckFailed(String)
} derive(Eq)

///|
pub extend Phase with Eq::{equal, not_equal}

///|
pub struct State {
  /// The conversation the phase describes; `None` before the overview first
  /// shows.
  conversation : @interop.ConversationKey?
  phase : Phase
  /// Counts list questions, so the answer to a superseded one is recognized
  /// and dropped instead of overwriting its successor's.
  serial : Int32
  /// Removals of the conversation's items the host has not answered yet;
  /// their rows stay on show without a second remove button.
  removing : Array[@protocol.SessionArtifact]
  /// Why the last removal for the conversation failed, until the next one
  /// succeeds or the overview moves to another conversation.
  remove_error : String?
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
pub fn State::initial() -> State {
  {
    conversation: None,
    phase: Unchecked,
    serial: 0,
    removing: [],
    remove_error: None,
  }
}

///|
/// What there is to show for `conversation`. An answer belongs to the
/// conversation it was asked about: for any other, nothing has been asked.
pub fn State::phase_for(
  self : State,
  conversation : @interop.ConversationKey,
) -> Phase {
  if self.conversation == Some(conversation) {
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
    // One question at a time per conversation; another conversation's
    // supersedes it. Another client may have changed the list while the
    // overview was away, so every arrival asks, with the last answer on show.
    Opened(conversation) =>
      match state.phase_for(conversation) {
        Checking | Reloading(_) => (@cmd.none, state)
        Loaded(artifacts) =>
          ask(emit, conversation, state, waiting=Reloading(artifacts))
        Unchecked | CheckFailed(_) =>
          ask(emit, conversation, state, waiting=Checking)
      }
    // A change to a list the overview is not showing changes nothing here:
    // that conversation is asked about when the overview shows it. For the
    // one it is showing, a question already out may have been answered
    // before the change, so it is superseded rather than awaited.
    Changed(conversation) => {
      guard state.conversation == Some(conversation) else {
        return (@cmd.none, state)
      }
      let waiting = match state.phase {
        Loaded(artifacts) | Reloading(artifacts) => Reloading(artifacts)
        Unchecked | Checking | CheckFailed(_) => Checking
      }
      ask(emit, conversation, state, waiting~)
    }
    Listed(serial~, result) => {
      guard serial == state.serial && state.phase is (Checking | Reloading(_)) else {
        return (@cmd.none, state)
      }
      let phase = match result {
        Ok(list) => Loaded(list.artifacts)
        Err(message) => CheckFailed(message)
      }
      (@cmd.none, { ..state, phase, })
    }
    Remove(conversation, artifact) => {
      guard state.conversation == Some(conversation) &&
        !state.removing.contains(artifact) else {
        return (@cmd.none, state)
      }
      let cmd = @cmd.attempt(
        result => {
          emit(
            Removed(
              conversation,
              artifact,
              result.map_err(@interop.bridge_error_text),
            ),
          )
        },
        () => {
          @interop.bridge_request(
            conversation.channel,
            @commands.session_artifacts_remove,
            { session: conversation.session, artifact, },
          )
        },
      )
      (cmd, { ..state, removing: [..state.removing, artifact], })
    }
    // The reply is the list as the removal left it, which is newer than any
    // answer still out: that answer is superseded so it cannot put the item
    // back. Later changes arrive as `Changed`.
    Removed(conversation, artifact, result) => {
      guard state.conversation == Some(conversation) else {
        return (@cmd.none, state)
      }
      let removing = state.removing.filter(item => item != artifact)
      match result {
        Ok(list) =>
          (
            @cmd.none,
            {
              ..state,
              phase: Loaded(list.artifacts),
              serial: state.serial + 1,
              removing,
              remove_error: None,
            },
          )
        Err(message) =>
          (@cmd.none, { ..state, removing, remove_error: Some(message), })
      }
    }
  }
}

///|
/// Ask the host for `conversation`'s list, showing `waiting` until it answers.
/// A conversation the state did not describe starts with no removals of its
/// own.
fn ask(
  emit : @cmd.Emit[Msg],
  conversation : @interop.ConversationKey,
  state : State,
  waiting~ : Phase,
) -> (@cmd.Cmd, State) {
  let serial = state.serial + 1
  let cmd = @cmd.attempt(
    result => emit(Listed(serial~, result.map_err(@interop.bridge_error_text))),
    () => {
      @interop.bridge_request(
        conversation.channel,
        @commands.session_artifacts_list,
        { session: conversation.session, },
      )
    },
  )
  let state = if state.conversation == Some(conversation) {
    state
  } else {
    { ..state, removing: [], remove_error: None, }
  }
  (cmd, { ..state, conversation: Some(conversation), phase: waiting, serial, })
}
