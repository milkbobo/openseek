///|
priv struct Image {
  name : String
  url : String
}

///|
priv struct FileReference {
  path : String
  source_root : String
}

///|
/// Attachments belong to one unsent composer. Preparing a send does not clear
/// them: only an accepted start/steer/queue operation consumes the draft.
struct Draft {
  images : Array[Image]
  files : Array[FileReference]
}

///|
pub fn Draft::Draft() -> Draft {
  { images: [], files: [], }
}

///|
pub fn Draft::is_empty(self : Draft) -> Bool {
  self.images.is_empty() && self.files.is_empty()
}

///|
pub fn Draft::labels(self : Draft) -> Array[String] {
  [
    ..self.images.map(image => "Image · " + image.name),
    ..self.files.map(file => "File · " + file.path),
  ]
}

///|
pub fn Draft::clear(self : Draft) -> Unit {
  self.images.clear()
  self.files.clear()
}

///|
pub fn Draft::copy(self : Draft) -> Draft {
  { images: self.images.copy(), files: self.files.copy(), }
}

///|
pub fn Draft::image_urls(self : Draft) -> Array[String] {
  self.images.map(image => image.url)
}

///|
/// Queue edits replace text and its encoded file references. Images travel
/// separately and stay attached while that text is edited.
pub fn Draft::copy_images(self : Draft) -> Draft {
  { images: self.images.copy(), files: [], }
}

///|
/// Return a refused submission ahead of context attached to the newer draft.
pub fn Draft::prepend(self : Draft, submitted : Draft) -> Unit {
  let images = self.images.copy()
  let files = self.files.copy()
  self.clear()
  self.images.append(submitted.images)
  self.images.append(images)
  self.files.append(submitted.files)
  self.files.append(files)
}

///|
pub fn Draft::remove(self : Draft, index : Int32) -> Bool {
  if index >= 0 && index < self.images.length() {
    ignore(self.images.remove(index))
    true
  } else {
    let index = index - self.images.length()
    if index >= 0 && index < self.files.length() {
      ignore(self.files.remove(index))
      true
    } else {
      false
    }
  }
}

///|
async fn checkout_root(
  client : @client.Client,
  session : String,
  workspace : String,
) -> String {
  let reply = client.call(@commands.worktree_list, { workspace, })
  if reply.worktrees
    .iter()
    .find_first(tree => {
      tree.sessions.contains(session) || tree.codex_thread == Some(session)
    })
    is Some(tree) {
    guard tree.present else {
      fail("Repair this conversation's missing worktree before attaching files")
    }
    tree.path
  } else {
    workspace
  }
}

///|
/// `/attach` references a host path; `/upload` supplies client-local bytes.
/// Both use the host's existing attachment validation, MIME detection and
/// original-file import service, so documents and images retain their desktop
/// behavior rather than being pasted into an ad-hoc text representation.
pub async fn Draft::attach(
  self : Draft,
  client : @client.Client,
  session : String,
  workspace : String,
  source : @protocol.AttachmentSource,
) -> String {
  let source_root = checkout_root(client, session, workspace)
  let source = match source {
    AttachmentPath(path) if !path.has_prefix("/") =>
      @protocol.AttachmentPath(source_root + "/" + path)
    _ => source
  }
  let payload : @protocol.PrepareAttachmentPayload = {
    session,
    workspace,
    source,
  }
  let prepared = client.call(@commands.fs_prepare_attachment, payload)
  match prepared {
    AttachmentImage(name~, url~) => {
      if !self.images.any(image => image.url == url) {
        self.images.push({ name, url, })
      }
      "Attached image " + name
    }
    WorkspaceAttachment(path~) => {
      if !self.files.any(file => {
          file.path == path && file.source_root == source_root
        }) {
        self.files.push({ path, source_root, })
      }
      "Attached " + path
    }
    AttachmentUploadRequired(name~) => {
      let imported = client.call(@commands.fs_import_attachment, payload)
      self.files.push({ path: imported.path, source_root, })
      "Uploaded " + name
    }
  }
}

///|
fn attribute(value : String) -> String {
  value
  .replace_all(old="&", new="&amp;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\r", new="&#13;")
  .replace_all(old="\n", new="&#10;")
}

///|
fn Draft::prompt(self : Draft, task : String) -> String {
  if self.files.is_empty() {
    return task
  }
  let references = self.files
    .map(file => "<file path=\"\{attribute(file.path)}\"/>")
    .join("\n")
  let envelope = "<user_mentions>\n" + references + "\n</user_mentions>"
  if task.trim().is_empty() {
    envelope
  } else {
    task.trim().to_owned() + "\n\n" + envelope
  }
}

///|
/// Stage uploaded originals after first-send worktree creation, preserving
/// their workspace-relative references. Failed sends can retry without losing
/// the attachment draft; the host's staging operation is idempotent.
pub async fn Draft::prepare(
  self : Draft,
  client : @client.Client,
  session : String,
  workspace : String,
  task : String,
) -> (String, Array[String]) {
  for payload in self.stage_payloads(session, workspace) {
    ignore(client.call(@commands.fs_stage_attachments, payload))
  }
  (self.prompt(task), self.image_urls())
}

///|
fn Draft::stage_payloads(
  self : Draft,
  session : String,
  workspace : String,
) -> Array[@protocol.StageAttachmentsPayload] {
  let roots : Map[String, Array[String]] = Map([])
  for file in self.files {
    if file.path.has_prefix(".openseek/attachments/") {
      let paths = roots.get_or_init(file.source_root, () => [])
      if !paths.contains(file.path) {
        paths.push(file.path)
      }
    }
  }
  roots
  .iter()
  .map(pair => {
    let (source_root, paths) = pair
    @protocol.StageAttachmentsPayload::{
      session,
      workspace,
      source_root,
      paths,
    }
  })
  .collect()
}
