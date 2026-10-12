///|
/// Seed (or refresh) the mirror. A failed or malformed reply leaves the
/// current mirror in place — `auth.changed` corrects it on the next move.
pub fn fetch_status(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let status = @interop.bridge_request(
        Local,
        @commands.auth_status,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        _ => return
      }
      scheduler.add(emit(StatusLoaded(status)))
    })
    |> ignore
  })
}

///|
/// Run the loopback sign-in. The reply arrives only after the user's
/// browser round-trip, minutes later at the worst — the section shows an
/// in-progress state the whole while.
fn connect(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let status = @interop.bridge_request(
        Local,
        @commands.auth_connect,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => {
          scheduler.add(emit(ConnectFailed(@interop.bridge_error_text(error))))
          return
        }
      }
      scheduler.add(emit(ConnectFinished(status)))
    })
    |> ignore
  })
}

///|
/// Abort a waiting sign-in. The connect's own failure reply settles the
/// section, so this only surfaces its *own* failure (a dead bridge).
fn cancel(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let _ = @interop.bridge_request(
        Local,
        @commands.auth_cancel,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => {
          scheduler.add(
            emit(DisconnectFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
    })
    |> ignore
  })
}

///|
/// Sign out. Success comes back as the post-sign-out status.
fn disconnect(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let reply = @interop.bridge_request(
        Local,
        @commands.auth_disconnect,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => {
          scheduler.add(
            emit(DisconnectFailed(@interop.bridge_error_text(error))),
          )
          return
        }
      }
      scheduler.add(emit(StatusLoaded(reply)))
    })
    |> ignore
  })
}
