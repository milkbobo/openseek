///|
async fn State::attach(
  self : State,
  client : @client.Client,
  path : String,
) -> Unit {
  guard !self.active.key.archived else {
    fail("Unarchive this chat before attaching a file")
  }
  guard self.active.key.workspace is Some(workspace) && !path.trim().is_empty() else {
    fail("Usage: /attach SERVER_PATH (choose a workspace first)")
  }
  self.notice = self.active.attachments.attach(
    client,
    self.active.codex_id().unwrap_or(self.active.key.session),
    workspace,
    @protocol.AttachmentPath(attachment_path(path)),
  )
}

///|
async fn State::upload(
  self : State,
  client : @client.Client,
  path : String,
) -> Unit {
  guard !self.active.key.archived else {
    fail("Unarchive this chat before uploading a file")
  }
  guard self.active.key.workspace is Some(workspace) && !path.trim().is_empty() else {
    fail("Usage: /upload LOCAL_PATH (choose a workspace first)")
  }
  let path = attachment_path(path)
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  guard size > 0L && size <= 20L * 1024L * 1024L else {
    fail("Attachments must be nonempty and 20 MiB or smaller")
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  let name = upload_name(path)
  self.notice = self.active.attachments.attach(
    client,
    self.active.codex_id().unwrap_or(self.active.key.session),
    workspace,
    @protocol.AttachmentBytes(name~, data_base64=@base64.encode(bytes)),
  )
}

///|
async fn Chat::prepare_prompt(
  self : Chat,
  client : @client.Client,
  task : String,
) -> (String, Array[String]) {
  if self.attachments.is_empty() {
    return (task, [])
  }
  guard self.key.workspace is Some(workspace) else {
    fail("Select a workspace before sending attachments")
  }
  self.attachments.prepare(
    client,
    self.codex_id().unwrap_or(self.key.session),
    workspace,
    task,
  )
}

///|
fn attachment_path(value : String) -> String {
  let path = value.trim().to_owned()
  for quote in ["\"", "'"] {
    if path.strip_prefix(quote).bind(value => value.strip_suffix(quote))
      is Some(unquoted) {
      return unquoted.to_owned()
    }
  }
  path
}

///|
fn upload_name(path : String) -> String {
  path
  .replace_all(old="\\", new="/")
  .split("/")
  .last()
  .map(value => value.to_owned())
  .unwrap_or("attachment")
}
