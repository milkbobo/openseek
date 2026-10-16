///|
priv struct SshUi {
  hosts : Array[@protocol.SshProfile]
  command : String
  busy : Bool
  error : String?
  connecting : Map[String, String]
} derive(Eq)

///|
fn SshUi::empty() -> SshUi {
  { hosts: [], command: "", busy: false, error: None, connecting: Map([]), }
}

///|
priv enum SshMsg {
  Open
  Command(String)
  Save
  Loaded(Result[@protocol.SshProfiles, String])
  Saved(Result[@protocol.SshProfile, String])
  Connect(String)
  Disconnect(String)
  Select(@interop.ChannelId)
  Failed(String)
  Event(Json)
}

///|
fn ssh_load(dispatch : @cmd.Emit[Msg]) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      let result : Result[@protocol.SshProfiles, String] = Ok(
        @interop.bridge_request(
          Local,
          @commands.ssh_profiles,
          @protocol.NoPayload,
        ),
      ) catch {
        error => Err(@interop.bridge_error_text(error))
      }
      scheduler.add(dispatch(Ssh(Loaded(result))))
    })
    |> ignore
  })
}

///|
fn ssh_connect(
  dispatch : @cmd.Emit[Msg],
  id : String,
  disconnect~ : Bool = false,
) -> @cmd.Cmd {
  @cmd.custom_cmd(scheduler => {
    @js.Promise::from_async(() => {
      ignore(
        @interop.bridge_request(
          Local,
          if disconnect {
            @commands.ssh_disconnect
          } else {
            @commands.ssh_connect
          },
          { id, },
        ),
      ) catch {
        error =>
          scheduler.add(
            dispatch(Ssh(Failed(@interop.bridge_error_text(error)))),
          )
      }
    })
    |> ignore
  })
}

///|
fn Model::register_ssh(self : Model, profile : @protocol.SshProfile) -> Model {
  @interop.register_ssh_profile(profile)
  let channel : @interop.ChannelId = Remote(profile.id)
  let devices = if self.device_state(channel) is Some(_) {
    self.devices
  } else {
    self.devices + [empty_device_state(channel)]
  }
  {
    ..self,
    devices,
    ssh_ui: {
      ..self.ssh_ui,
      hosts: self.ssh_ui.hosts.filter(p => p.id != profile.id) + [profile],
    },
    console: {
      ..self.console,
      roster: self.console.roster.filter(p => p.id != profile.id) +
      [
        {
          id: profile.id,
          name: profile.command,
          hostname: None,
          online: false,
        },
      ],
    },
  }
}

///|
fn update_ssh(
  dispatch : @cmd.Emit[Msg],
  msg : SshMsg,
  model : Model,
) -> (@cmd.Cmd, Model) {
  guard model.is_desktop else { return (@cmd.none, model) }
  let ui = model.ssh_ui
  match msg {
    Open => {
      let (_, next) = update_msg(dispatch, OpenSetup, {
        ..model,
        project_picker: None,
      })
      let focus = @cmd.custom_cmd(
        _ => {
          if @dom.document().get_element_by_id("ssh-command").to_option()
            is Some(element) &&
            element.to_html_element() is Some(input) {
            input.focus()
          }
        },
        kind=@cmd.after_render,
      )
      (focus, next)
    }
    Command(value) =>
      (@cmd.none, { ..model, ssh_ui: { ..ui, command: value, }, })
    Failed(message) =>
      (
        @cmd.none,
        {
          ..model,
          ssh_ui: {
            ..ui,
            busy: false,
            error: Some(message),
            connecting: Map([]),
          },
        },
      )
    Loaded(Err(message)) | Saved(Err(message)) =>
      update_ssh(dispatch, Failed(message), model)
    Loaded(Ok(profiles)) => {
      let mut model = model
      for profile in profiles.hosts {
        model = model.register_ssh(profile)
      }
      (@cmd.none, model)
    }
    Save => {
      guard !ui.busy else { return (@cmd.none, model) }
      let command = @cmd.custom_cmd(scheduler => {
        @js.Promise::from_async(() => {
          let result : Result[@protocol.SshProfile, String] = try {
            match
              @interop.bridge_request(Local, @commands.ssh_save, {
                id: "",
                command: ui.command,
                server: "openseek",
              }) {
              SshSuccess(value) => Ok(@json.from_json(value))
              SshUnsent(message) | SshRefused(message) | SshUnknown(message) =>
                Err(message)
            }
          } catch {
            error => Err(@interop.bridge_error_text(error))
          }
          scheduler.add(dispatch(Ssh(Saved(result))))
        })
        |> ignore
      })
      (command, { ..model, ssh_ui: { ..ui, busy: true, error: None, }, })
    }
    Saved(Ok(profile)) => {
      let model = model.register_ssh(profile)
      update_ssh(dispatch, Connect(profile.id), {
        ..model,
        ssh_ui: { ..model.ssh_ui, busy: false, command: "", },
      })
    }
    Connect(id) => {
      let connecting = ui.connecting.copy()
      connecting[id] = "Connecting…"
      @interop.set_ssh_epoch(Remote(id), None)
      (
        ssh_connect(dispatch, id),
        { ..model, ssh_ui: { ..ui, connecting, error: None, }, },
      )
    }
    Disconnect(id) => {
      let connecting = ui.connecting.copy()
      connecting.remove(id)
      let model = { ..model, ssh_ui: { ..ui, connecting, }, }
      @interop.set_ssh_epoch(Remote(id), None)
      let (cmd, model) = update_device_msg(
        dispatch,
        Remote(id),
        BridgeUnavailable("SSH disconnected"),
        model,
      )
      (@cmd.batch([cmd, ssh_connect(dispatch, id, disconnect=true)]), model)
    }
    Select(channel) => {
      let (cmd, model) = focus_channel(dispatch, model, channel)
      let (next, model) = update(dispatch, PickProject(channel), model)
      (@cmd.batch([cmd, next]), model)
    }
    Event(value) => {
      guard value
        is {
          "host_id": String(id),
          "epoch": Number(epoch, ..),
          "event": event,
          ..
        } else {
        return (@cmd.none, model)
      }
      let channel : @interop.ChannelId = Remote(id)
      let epoch = epoch.to_int()
      if event is { "stage": String(stage), .. } && ui.connecting.contains(id) {
        let connecting = ui.connecting.copy()
        connecting[id] = match stage {
          "downloading" => "Downloading OpenSeek…"
          "installing" => "Running openseek setup…"
          _ => "Connecting…"
        }
        return (@cmd.none, { ..model, ssh_ui: { ..ui, connecting, }, })
      }
      if event is { "method": "agent.connected", .. } {
        if @interop.current_ssh_epoch(channel) is Some(current) &&
          current > epoch {
          return (@cmd.none, model)
        }
        @interop.set_ssh_epoch(channel, Some(epoch))
        let connecting = ui.connecting.copy()
        connecting.remove(id)
        return update_device_msg(dispatch, channel, BridgeReady, {
          ..model,
          ssh_ui: { ..ui, connecting, },
        })
      }
      if event is { "disconnected": String(message), .. } {
        if @interop.current_ssh_epoch(channel) is Some(current) &&
          current != epoch {
          return (@cmd.none, model)
        }
        @interop.set_ssh_epoch(channel, None)
        let connecting = ui.connecting.copy()
        connecting.remove(id)
        let (cmd, model) = update_device_msg(
          dispatch,
          channel,
          BridgeUnavailable(message),
          model,
        )
        return (
          cmd,
          { ..model, ssh_ui: { ..ui, connecting, error: Some(message), }, },
        )
      }
      guard @interop.current_ssh_epoch(channel) == Some(epoch) &&
        event is { "method": String(method_), "params": params, .. } &&
        @protocol.Notification::from_wire(method_, params) is Some(notification) else {
        return (@cmd.none, model)
      }
      (bridge_notification(dispatch, channel, notification), model)
    }
  }
}

///|
fn ssh_settings(dispatch : @cmd.Emit[Msg], model : Model) -> @html.Html {
  let ui = model.ssh_ui
  let rows : Array[@html.Html] = []
  rows.push(
    @settings.row("This computer", [
      @html.button(
        class="button secondary",
        on_click=dispatch(Ssh(Select(Local))),
        "Add local project",
      ),
    ]),
  )
  for host in ui.hosts {
    let online = model.device_state(Remote(host.id))
      is Some({ bridge: Connected, .. })
    let connecting = ui.connecting.contains(host.id)
    rows.push(
      @settings.row(host.command, [
        @html.span(
          if connecting {
            ui.connecting.get(host.id).unwrap_or("Connecting…")
          } else if online {
            "Connected"
          } else {
            "Offline"
          },
        ),
        @html.button(
          class="button secondary",
          disabled=!online,
          on_click=dispatch(Ssh(Select(Remote(host.id)))),
          "Add project",
        ),
        @html.button(
          class="button secondary",
          on_click=dispatch(
            Ssh(
              if online || connecting {
                Disconnect(host.id)
              } else {
                Connect(host.id)
              },
            ),
          ),
          if connecting {
            "Cancel"
          } else if online {
            "Disconnect"
          } else {
            "Connect"
          },
        ),
      ]),
    )
  }
  rows.push(
    @settings.row(
      "SSH command",
      [
        @html.input(
          value=ui.command,
          placeholder="ssh -p 22 user@host",
          attrs=@html.Attrs::build()
            .id("ssh-command")
            .aria_label("SSH command")
            .disabled(ui.busy),
          on_input=dispatch.map(value => Ssh(Command(value))),
        ),
      ],
      desc="SeekMoon downloads OpenSeek CLI and runs openseek setup on this host automatically. Use an SSH key or agent and a trusted host in ~/.ssh/known_hosts. Options: -p, -i, -J, -l, -F.",
    ),
  )
  rows.push(
    @settings.row("Add SSH remote", [
      @html.button(
        class="button primary",
        disabled=ui.busy || ui.command.trim().is_empty(),
        on_click=dispatch(Ssh(Save)),
        if ui.busy {
          "Saving…"
        } else {
          "Add and connect"
        },
      ),
    ]),
  )
  if ui.error is Some(message) {
    rows.push(
      @html.p(
        attrs=@html.Attrs::build().role("alert"),
        class="ssh-error",
        message,
      ),
    )
  }
  @settings.group(@icons.icon_folder, "SSH remotes", rows)
}

///|
fn ssh_locations(dispatch : @cmd.Emit[Msg], model : Model) -> @html.Html {
  let choices = [
    @html.button(
      class="button secondary",
      on_click=dispatch(Ssh(Select(Local))),
      "This computer",
    ),
  ]
  for host in model.ssh_ui.hosts {
    let online = model.device_state(Remote(host.id))
      is Some({ bridge: Connected, .. })
    choices.push(
      @html.button(
        class="button secondary",
        disabled=!online,
        on_click=dispatch(Ssh(Select(Remote(host.id)))),
        host.command + (if online { "" } else { " (offline)" }),
      ),
    )
  }
  choices.push(
    @html.button(
      class="button secondary",
      on_click=dispatch(Ssh(Open)),
      "Add SSH remote…",
    ),
  )
  @html.div(
    class="ssh-locations",
    attrs=@html.Attrs::build().aria_label("Project location"),
    choices,
  )
}
