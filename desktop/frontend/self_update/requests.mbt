///|
/// The app's own check, once the bridge can carry it. It stays quiet unless
/// something is actionable.
pub fn check_at_startup(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  check(emit, explicit=false)
}

///|
/// Ask the host to check the release manifest. Every outcome lands in
/// `CheckFinished`: op failures (bridge missing, host error) fold into
/// `Unreachable`, so the handler has one shape to route.
fn check(emit : @cmd.Emit[Msg], explicit~ : Bool) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let reply = @interop.bridge_request(
        Local,
        @commands.update_check,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        error => @protocol.Unreachable(reason=@interop.bridge_error_text(error))
      }
      scheduler.add(emit(CheckFinished(reply~, explicit~)))
    })
    |> ignore
  })
}

///|
/// Ask the host-owned update actor to download and verify the release
/// package. A successful reply only means the work was accepted;
/// `update.downloaded` triggers `Downloaded` after staging, and
/// `update.download_failed` carries a background failure.
fn download(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      ignore(
        @interop.bridge_request(
          Local,
          @commands.update_download,
          @protocol.EmptyPayload::NoPayload,
        ) catch {
          error => {
            scheduler.add(
              emit(Failed(message=@interop.bridge_error_text(error))),
            )
            return
          }
        },
      )
    })
    |> ignore
  })
}

///|
/// Ask the host to swap the staged update into place. Success means the
/// bundle on disk is already the new version; the follow-up `Applied`
/// closes the window so `main` can relaunch it. A failure reports why and
/// the app keeps running the current version.
fn apply(emit : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      ignore(
        @interop.bridge_request(
          Local,
          @commands.update_apply,
          @protocol.EmptyPayload::NoPayload,
        ) catch {
          error => {
            scheduler.add(
              emit(Failed(message=@interop.bridge_error_text(error))),
            )
            return
          }
        },
      )
      scheduler.add(emit(Applied))
    })
    |> ignore
  })
}

///|
/// Close the window through the normal close path — the same teardown as
/// the user clicking the close button, so engines and the host unwind
/// before `main` relaunches the swapped bundle.
fn close_window() -> @cmd.Cmd {
  @cmd.custom_cmd(_ => {
    let _ : @js.Value = @js.globalThis.apply_with_string(
      "close",
      ([] : FixedArray[@js.Value]),
    )
  })
}
