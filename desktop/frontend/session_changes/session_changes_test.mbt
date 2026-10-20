///|
fn quiet() -> @cmd.Emit[@session_changes.Msg] {
  Emit(_ => @cmd.none)
}

///|
fn conversation(session : String) -> @interop.ConversationKey {
  { channel: Local, session, }
}

///|
fn pull(number : Int32) -> @protocol.SessionArtifact {
  @json.from_json({
    "type": "pull_request",
    "url": "https://github.com/moonbitlang/openseek/pull/\{number}",
  }) catch {
    error => abort(error.to_string())
  }
}

///|
fn branch(name : String) -> @protocol.SessionArtifact {
  @json.from_json({
    "type": "branch",
    "url": "https://github.com/moonbitlang/openseek/tree/\{name}",
  }) catch {
    error => abort(error.to_string())
  }
}

///|
fn listed(
  artifacts : Array[@protocol.SessionArtifact],
) -> Result[@protocol.SessionArtifacts, String] {
  Ok(
    artifacts.fold(init=@protocol.SessionArtifacts::empty(), (list, artifact) => {
      list.attach(artifact)
    }),
  )
}

///|
/// Open the overview on `key` and answer with `artifacts`.
fn loaded(
  key : @interop.ConversationKey,
  artifacts : Array[@protocol.SessionArtifact],
) -> @session_changes.State {
  let (_, checking) = @session_changes.update(
    quiet(),
    Opened(key),
    @session_changes.State::initial(),
  )
  let (_, loaded) = @session_changes.update(
    quiet(),
    Listed(serial=checking.serial, listed(artifacts)),
    checking,
  )
  loaded
}

///|
test "opening the overview asks for the list, every time" {
  let one = conversation("s-1")
  let (_, checking) = @session_changes.update(
    quiet(),
    Opened(one),
    @session_changes.State::initial(),
  )
  assert_true(checking.phase is Checking)
  assert_true(checking.conversation == Some(one))
  let (_, answered) = @session_changes.update(
    quiet(),
    Listed(serial=checking.serial, listed([pull(1)])),
    checking,
  )
  assert_true(answered.phase is Loaded([item]) && item == pull(1))
  // Another client may have attached something meanwhile, so coming back
  // asks again with the last answer on show.
  let (_, reopened) = @session_changes.update(quiet(), Opened(one), answered)
  assert_true(reopened.phase is Reloading([item]) && item == pull(1))
  assert_true(reopened.serial != answered.serial)
  // A question already out is not asked twice.
  let (_, again) = @session_changes.update(quiet(), Opened(one), reopened)
  assert_true(again == reopened)
}

///|
test "the answer to a superseded question is dropped" {
  let (_, first) = @session_changes.update(
    quiet(),
    Opened(conversation("s-1")),
    @session_changes.State::initial(),
  )
  let (_, second) = @session_changes.update(
    quiet(),
    Opened(conversation("s-2")),
    first,
  )
  let (_, stale) = @session_changes.update(
    quiet(),
    Listed(serial=first.serial, listed([pull(1)])),
    second,
  )
  assert_true(stale == second)
  let (_, failed) = @session_changes.update(
    quiet(),
    Listed(serial=second.serial, Err("device offline")),
    second,
  )
  assert_true(failed.phase is CheckFailed("device offline"))
  // An answer cannot arrive twice.
  let (_, again) = @session_changes.update(
    quiet(),
    Listed(serial=second.serial, listed([])),
    failed,
  )
  assert_true(again == failed)
}

///|
test "a saved change asks again only for the conversation on show" {
  let one = conversation("s-1")
  let state = loaded(one, [pull(1)])
  let (_, other) = @session_changes.update(
    quiet(),
    Changed(conversation("s-2")),
    state,
  )
  assert_true(other == state)
  let (_, changed) = @session_changes.update(quiet(), Changed(one), state)
  assert_true(changed.phase is Reloading([item]) && item == pull(1))
  // A question already out may predate the change, so it is superseded.
  let (_, superseded) = @session_changes.update(quiet(), Changed(one), changed)
  assert_true(superseded.serial != changed.serial)
  let (_, stale) = @session_changes.update(
    quiet(),
    Listed(serial=changed.serial, listed([pull(1)])),
    superseded,
  )
  assert_true(stale == superseded)
  let (_, settled) = @session_changes.update(
    quiet(),
    Listed(serial=superseded.serial, listed([pull(1), branch("feature")])),
    superseded,
  )
  assert_true(settled.phase is Loaded([_, _]))
}

///|
test "removing an item waits for the host, then reads the list again" {
  let one = conversation("s-1")
  let state = loaded(one, [pull(1), branch("feature")])
  let (_, removing) = @session_changes.update(
    quiet(),
    Remove(one, pull(1)),
    state,
  )
  assert_true(removing.removing == [pull(1)])
  // The row stays until the host answers, and is not removed twice.
  assert_true(removing.phase == state.phase)
  let (_, twice) = @session_changes.update(
    quiet(),
    Remove(one, pull(1)),
    removing,
  )
  assert_true(twice == removing)
  // Another client attaches a pull request while the removal is out; the
  // list question that announcement starts may still predate the removal.
  let (_, asked) = @session_changes.update(quiet(), Changed(one), removing)
  let (_, removed) = @session_changes.update(
    quiet(),
    Removed(one, pull(1), listed([branch("feature")])),
    asked,
  )
  // What the removal left shows at once, and the list is asked for again:
  // the removal's reply is not the last word on it.
  assert_true(removed.phase is Reloading([item]) && item == branch("feature"))
  assert_true(removed.removing.is_empty())
  assert_true(removed.serial != asked.serial)
  let (_, stale) = @session_changes.update(
    quiet(),
    Listed(serial=asked.serial, listed([pull(1), branch("feature")])),
    removed,
  )
  assert_true(stale == removed)
  // The fresh answer keeps the other client's attachment.
  let (_, settled) = @session_changes.update(
    quiet(),
    Listed(serial=removed.serial, listed([pull(3)])),
    removed,
  )
  assert_true(settled.phase is Loaded([item]) && item == pull(3))
}

///|
test "a failed removal keeps the item and says why until one succeeds" {
  let one = conversation("s-1")
  let state = loaded(one, [pull(1), pull(2)])
  let (_, removing) = @session_changes.update(
    quiet(),
    Remove(one, pull(1)),
    state,
  )
  let (_, failed) = @session_changes.update(
    quiet(),
    Removed(one, pull(1), Err("the session is archived")),
    removing,
  )
  assert_true(failed.phase == state.phase)
  assert_true(failed.removing.is_empty())
  assert_true(failed.remove_error == Some("the session is archived"))
  let (_, retried) = @session_changes.update(
    quiet(),
    Remove(one, pull(2)),
    failed,
  )
  let (_, removed) = @session_changes.update(
    quiet(),
    Removed(one, pull(2), listed([pull(1)])),
    retried,
  )
  assert_true(removed.remove_error is None)
  // Another conversation starts without the first one's error.
  let (_, other) = @session_changes.update(
    quiet(),
    Opened(conversation("s-2")),
    failed,
  )
  assert_true(other.remove_error is None)
}

///|
test "the folded summary counts the checkout and what is attached" {
  let one = conversation("s-1")
  let current : @session_changes.PullRequest = {
    number: 1,
    title: "Add the changes card",
    state: Open,
    url: pull(1).url,
  }
  let on_branch : @session_changes.Checkout = {
    branch: "feature",
    pull_request: None,
    diff: Some({ added: 3, removed: 1, files: 2, partial: false, }),
  }
  let on_pull_request = { ..on_branch, pull_request: Some(current), }
  // Nothing to describe: the card stays away, even while the list is read.
  let initial = @session_changes.State::initial()
  assert_true(@session_changes.summary(one, None, initial) is None)
  assert_true(@session_changes.summary(one, None, loaded(one, [])) is None)
  assert_true(
    @session_changes.summary(one, Some(on_branch), initial) == Some("1 branch"),
  )
  // The checkout's pull request attached as well is one row, not two.
  let state = loaded(one, [pull(1), pull(2), branch("other")])
  assert_true(
    @session_changes.summary(one, Some(on_pull_request), state) ==
    Some("2 PRs · 1 branch"),
  )
  assert_true(
    @session_changes.rows(one, Some(on_pull_request), state, quiet()).length() ==
    3,
  )
  assert_true(
    @session_changes.summary(
      locale=SimplifiedChinese,
      one,
      Some(on_branch),
      state,
    ) ==
    Some("2 个 PR · 2 个分支"),
  )
  // Another conversation's answer is not this one's.
  assert_true(
    @session_changes.summary(conversation("s-2"), None, state) is None,
  )
  // A list that could not be read is still worth a card.
  let (_, checking) = @session_changes.update(quiet(), Opened(one), initial)
  let (_, failed) = @session_changes.update(
    quiet(),
    Listed(serial=checking.serial, Err("device offline")),
    checking,
  )
  assert_true(
    @session_changes.summary(one, None, failed) ==
    Some("The attached changes could not be read"),
  )
  assert_true(@session_changes.rows(one, None, failed, quiet()).length() == 1)
}
