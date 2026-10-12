// What the root contributes to the `self_update` package's flow: the
// installed version shown beside it, and whether a restart would interrupt
// a conversation.

///|
/// Read immutable installed-package metadata from the desktop host. This is a
/// separate operation from settings because changing a preference must never
/// change the version shown by the application.
fn Model::fetch_app_info(self : Model, dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  guard self.is_desktop else { return @cmd.none }
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let reply = @interop.bridge_request(
        Local,
        @commands.app_info,
        @protocol.EmptyPayload::NoPayload,
      ) catch {
        _ => return
      }
      scheduler.add(
        dispatch(
          AppInfoLoaded(version=reply.version, console_url=reply.console_url),
        ),
      )
    })
    |> ignore
  })
}

///|
/// Whether restarting now would cut a conversation off mid-run.
fn Model::any_conversation_busy(self : Model) -> Bool {
  self.conversations.any(conv => {
    conv.is_running() || !(conv.compaction is NotCompacting)
  })
}
