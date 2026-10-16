///|
// Serialize saves across clients of this shared server. Both checking the
// baseline and committing it belong inside this section, so two saves from
// the same loaded version cannot both overwrite one another successfully.
let editor_save_lock : @async.Mutex = Mutex()

///|
async fn write_file_op(
  payload : @protocol.WriteFilePayload,
) -> @protocol.WriteFileReply {
  let file = if payload.root is Some(root) {
    WirePath::parse(root).resolve(payload.path)
  } else {
    WirePath::parse(payload.path).absolute
  }
  let native = file.to_string()
  let resource = file.resource_path()
  editor_save_lock.acquire()
  defer editor_save_lock.release()
  if payload.expected_content is Some(expected) {
    let source = @fs.open(native, mode=ReadOnly) catch {
      @os_error.OSError(_) as error if error.is_ENOENT() =>
        raise HostError(
          "file changed on disk: the loaded file no longer exists",
        )
      error => raise HostError("failed to read file before save: \{error}")
    }
    defer source.close()
    let baseline = @utf8.encode(expected)
    // A changed size proves a conflict without allocating an unexpectedly
    // large replacement file that the user never loaded in the editor.
    if source.size() != baseline.length().to_int64() ||
      source.read_all().binary() != baseline {
      raise HostError("file changed on disk: reload before saving")
    }
    @fs.write_file(native, payload.content, create_mode=TruncateExisting) catch {
      @os_error.OSError(_) as error if error.is_ENOENT() =>
        raise HostError(
          "file changed on disk: the loaded file no longer exists",
        )
      error => raise HostError("failed to save file: \{error}")
    }
  } else {
    @fs.write_file(native, payload.content, create_mode=CreateNew) catch {
      @os_error.OSError(_) as error if error.is_EEXIST() =>
        raise HostError("file changed on disk: the new file already exists")
      error => raise HostError("failed to create file: \{error}")
    }
  }
  { path: resource, }
}
