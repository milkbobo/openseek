///|
fn emit() -> @cmd.Emit[@remote_access.Msg] {
  @cmd.Emit(_ => @cmd.none)
}

///|
fn signed_out() -> @protocol.AuthStatusPayload {
  {
    connected: false,
    server_url: Some("https://relay.example"),
    managed_by_env: None,
    user: None,
    device: None,
  }
}

///|
fn signed_in() -> @protocol.AuthStatusPayload {
  {
    ..signed_out(),
    connected: true,
    user: Some({ login: "octocat", avatar_url: "", }),
  }
}

///|
test "remote access walks connect states and dedups clicks" {
  let (seeded, _) = @remote_access.update(
    @remote_access.State::empty(),
    StatusLoaded(signed_out()),
    emit(),
  )
  assert_true(seeded.status is Some({ user_login: None, .. }))
  let (connecting, _) = @remote_access.update(seeded, ConnectClicked, emit())
  assert_true(connecting.connecting)
  // A second click while the browser round-trip is pending is a no-op.
  let (second, _) = @remote_access.update(connecting, ConnectClicked, emit())
  assert_true(second == connecting)
  let (failed, _) = @remote_access.update(
    connecting,
    ConnectFailed("nope"),
    emit(),
  )
  assert_false(failed.connecting)
  assert_true(failed.error is Some("nope"))
  let (done, _) = @remote_access.update(
    connecting,
    ConnectFinished(signed_in()),
    emit(),
  )
  assert_false(done.connecting)
  assert_true(
    done.status is Some({ user_login: Some("octocat"), connected: true, .. }),
  )
  // A broadcast keeps the mirror fresh without touching the pending flag.
  let (broadcast, _) = @remote_access.update(
    connecting,
    StatusLoaded(signed_out()),
    emit(),
  )
  assert_true(broadcast.connecting)
}

///|
test "auth status payloads decode by shape" {
  let (state, _) = @remote_access.update(
    @remote_access.State::empty(),
    StatusLoaded({
      connected: true,
      server_url: Some("https://relay.example"),
      managed_by_env: None,
      user: Some({ login: "octocat", avatar_url: "", }),
      device: Some({
        id: "d_abc",
        name: "My Mac",
        url: "https://relay.example/d/d_abc/",
      }),
    }),
    emit(),
  )
  guard state.status is Some(status) else { fail("expected a loaded status") }
  assert_true(status.connected)
  assert_true(status.user_login is Some("octocat"))
  assert_true(status.device_url is Some("https://relay.example/d/d_abc/"))
  let (state, _) = @remote_access.update(
    state,
    StatusLoaded({
      connected: false,
      server_url: None,
      managed_by_env: None,
      user: None,
      device: None,
    }),
    emit(),
  )
  assert_true(state.status is Some({ user_login: None, .. }))
}
