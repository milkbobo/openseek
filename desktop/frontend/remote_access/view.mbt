///|
using @icons {icon, icon_link_external}

///|
/// The Remote access group's rows: sign-in state against the SeekMoon
/// relay. The relay no longer depends on the chat provider — only the
/// hosted chat proxy was retired — so it is always available.
pub fn rows(
  locale : @i18n.Locale,
  emit : @cmd.Emit[Msg],
  state : State,
) -> Array[@html.Html] {
  let rows : Array[@html.Html] = []
  match state.status {
    None =>
      rows.push(
        @settings.row(
          @settings.text(locale, RemoteControl),
          [],
          desc=@settings.text(locale, CheckingSignIn),
        ),
      )
    Some(status) =>
      if status.managed_by_env {
        rows.push(
          @settings.row(
            @settings.text(locale, RemoteControl),
            [],
            desc=@settings.text(locale, EnvironmentRelay),
          ),
        )
      } else if status.user_login is Some(login) {
        let presence = if status.connected {
          @settings.text(locale, OnlineRelay)
        } else {
          @settings.text(locale, ConnectingRelay)
        }
        rows.push(
          @settings.row(
            @settings.text(locale, SignedInAs),
            [
              @html.button(
                class="button secondary",
                on_click=emit(DisconnectClicked),
                @settings.text(locale, Disconnect),
              ),
            ],
            desc="@\{login} — \{presence}",
          ),
        )
        if status.device_url is Some(url) {
          let name = status.device_name.unwrap_or(
            @settings.text(locale, ThisMachine),
          )
          rows.push(
            @settings.row(
              @settings.text(locale, DevicePage),
              [
                // The shared external-link listener keeps the desktop webview
                // in place and hands this URL to the system browser.
                @html.a(
                  class="button secondary setting-link",
                  href=url,
                  target=Blank,
                  rel="noopener noreferrer",
                  [
                    icon(icon_link_external),
                    @html.span(@settings.text(locale, Open)),
                  ],
                ),
              ],
              desc=@settings.text(locale, DevicePageDescription(name, url)),
            ),
          )
        }
      } else {
        let target = match status.server_url {
          Some(server) => @settings.text(locale, RegisterServer(server))
          None => @settings.text(locale, RegisterRelay)
        }
        let controls : Array[@html.Html] = [
          // Once the sign-in completes this same slot becomes the Disconnect
          // button, and rabbita patches the existing element. `disabled~`
          // would set a DOM property, which its diff cannot clear (`delete`
          // on a prototype accessor is a no-op), leaving Disconnect dead; the
          // attribute form is removed correctly.
          @html.button(
            class="button primary",
            attrs=@html.Attrs::build().disabled(state.connecting),
            on_click=emit(ConnectClicked),
            if state.connecting {
              @settings.text(locale, WaitingBrowser)
            } else {
              @settings.text(locale, ConnectGitHub)
            },
          ),
        ]
        // Appended after the stable Connect button, so its appearance
        // never re-seats that node.
        if state.connecting {
          controls.push(
            @html.button(
              class="button secondary",
              on_click=emit(CancelClicked),
              @settings.text(locale, Cancel),
            ),
          )
        }
        rows.push(
          @settings.row(@settings.text(locale, SignIn), controls, desc=target),
        )
      }
  }
  if state.error is Some(message) {
    rows.push(@settings.row(@settings.text(locale, Problem), [], desc=message))
  }
  rows
}
