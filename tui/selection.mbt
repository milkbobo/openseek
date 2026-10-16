///|
/// The explorer follows the selected conversation's resolved checkout. Clear
/// its previous project before any request, including requests that may fail.
async fn State::refresh_selected_workspace(
  self : State,
  client : @client.Client,
) -> Unit {
  self.workspace.clear()
  if self.active.key.workspace is Some(_) {
    self.workspace.browse(client, self.context())
  } else {
    ignore(client.call(@commands.fs_unwatch, @protocol.NoPayload))
  }
}

///|
async fn State::start_chat(
  self : State,
  client : @client.Client,
  workspace : String?,
) -> Unit {
  self.new_chat(workspace)
  self.refresh_selected_workspace(client)
}

///|
fn file_argument(text : String) -> String raise @workbench.InputError {
  let args = @workbench.arguments(text)
  guard args.length() == 1 && args.get(0) is Some(path) && !path.is_empty() else {
    raise @workbench.InputError(
      "Expected one file or directory path; quote paths containing spaces",
    )
  }
  path
}
