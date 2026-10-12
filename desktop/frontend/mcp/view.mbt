///|
/// The rows of the Settings page's MCP group for `host`: the explanation
/// with its check button, then what the last check of that host found.
pub fn rows(
  locale~ : @i18n.Locale = English,
  host~ : @interop.ChannelId,
  state : State,
  emit : @cmd.Emit[Msg],
) -> Array[@html.Html] {
  let phase = state.phase_for(host)
  let checking = phase is Checking
  let rows : Array[@html.Html] = [
    @settings.row(
      text(locale, Servers),
      [
        @html.button(
          class="button secondary",
          disabled=checking,
          on_click=emit(Refresh(host)),
          text(locale, if checking { Checking } else { CheckAgain }),
        ),
      ],
      desc=text(locale, Description),
    ),
  ]
  match phase {
    Unchecked => ()
    Checking => rows.push(note(text(locale, Connecting)))
    CheckFailed(reason) => rows.push(problem(text(locale, CheckFailed), reason))
    Loaded(NoConfig(path~)) =>
      rows.push(note(text(locale, NotConfigured(path))))
    Loaded(ConfigRejected(path~, reason~)) =>
      rows.push(problem(text(locale, ConfigRejected(path)), reason))
    Loaded(Configured(path~, servers=[])) =>
      rows.push(note(text(locale, NoServers(path))))
    Loaded(Configured(servers~, ..)) =>
      for server in servers {
        rows.push(server_row(locale, server))
      }
  }
  rows
}

///|
/// A row that only says something: nothing to operate, nothing went wrong.
fn note(message : String) -> @html.Html {
  @html.div(class="setting-row", [
    @html.div(class="setting-text", [@html.div(class="setting-desc", message)]),
  ])
}

///|
/// A row for something that went wrong, with the reason in the words of
/// whoever reported it (the host or the engine).
fn problem(title : String, reason : String) -> @html.Html {
  @html.div(class="setting-row", [
    @html.div(class="setting-text", [
      @html.div(class="setting-name", title),
      @html.div(class="setting-desc mcp-error", reason),
    ]),
  ])
}

///|
fn server_row(
  locale : @i18n.Locale,
  server : @protocol.McpServerStatus,
) -> @html.Html {
  let transport = match server.transport {
    Stdio => "stdio"
    Http => "http"
  }
  let details : Array[@html.Html] = [
    @html.div(class="setting-name", server.name),
    @html.div(class="setting-desc", "\{transport} · \{server.target}"),
  ]
  let (badge_class, badge) = match server.state {
    Connected(tools) => {
      details.push(
        @html.details(class="mcp-tools", [
          @html.summary(text(locale, ToolCount(tools.length()))),
          @html.ul(
            [
              for tool in tools => {
                @html.li(title=tool.description, [@html.code(tool.name)])
              }
            ],
          ),
        ]),
      )
      ("mcp-state ok", Connected)
    }
    NoTools => {
      details.push(@html.div(class="setting-desc", text(locale, NoToolsReason)))
      ("mcp-state", NoTools)
    }
    Failed(error) => {
      details.push(@html.div(class="setting-desc mcp-error", error))
      ("mcp-state error", Failed)
    }
    Skipped => {
      details.push(@html.div(class="setting-desc", text(locale, SkippedReason)))
      ("mcp-state", Skipped)
    }
  }
  @html.div(class="setting-row mcp-server", [
    @html.div(class="setting-text", details),
    @html.span(class=badge_class, text(locale, badge)),
  ])
}
