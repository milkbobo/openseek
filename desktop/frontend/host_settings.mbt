///|
fn host_settings_emit(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  connection_generation : Int32,
) -> @cmd.Emit[@host_settings.Msg] {
  dispatch.map(msg => {
    FromDevice(
      channel,
      HostSettings(msg, connection_generation=Some(connection_generation)),
    )
  })
}

///|
fn fetch_host_settings(
  dispatch : @cmd.Emit[Msg],
  channel : @interop.ChannelId,
  connection_generation : Int32,
) -> @cmd.Cmd {
  @host_settings.fetch_status(
    host_settings_emit(dispatch, channel, connection_generation),
    channel,
  )
}

///|
fn Model::host_settings_menu(
  self : Model,
  dispatch : @cmd.Emit[Msg],
) -> @host_settings.Menu {
  {
    open: self.select_menu == Some(ApiProviderMenu),
    toggle: dispatch(ToggleSelectMenu(ApiProviderMenu)),
    dismiss: dispatch(CloseSelectMenu),
  }
}

///|
fn api_settings_rows(
  dispatch : @cmd.Emit[Msg],
  model : Model,
) -> Array[@html.Html] {
  @host_settings.api_settings_rows(
    dispatch.map(msg => HostSettings(msg)),
    model.host_settings,
    model.locale,
    is_desktop=model.is_desktop,
    menu=model.host_settings_menu(dispatch),
  )
}

///|
fn api_setup_modal(dispatch : @cmd.Emit[Msg], model : Model) -> @html.Html {
  @host_settings.api_setup_modal(
    dispatch.map(msg => HostSettings(msg)),
    model.host_settings,
    model.locale,
    is_desktop=model.is_desktop,
    menu=model.host_settings_menu(dispatch),
  )
}

///|
fn Model::host_settings_loaded(self : Model) -> Bool {
  self.host_settings.loaded()
}

///|
fn Model::clear_host_settings(self : Model) -> Model {
  { ..self, host_settings: self.host_settings.clear(), }
}

///|
fn Model::api_ready(self : Model) -> Bool {
  self.host_settings.api_ready()
}
