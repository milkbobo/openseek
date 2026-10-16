///|
async fn expect_editor_save_conflict(
  payload : @protocol.WriteFilePayload,
) -> Unit {
  try write_file_op(payload) catch {
    HostError(message) => assert_true(message.contains("file changed on disk"))
    error => raise error
  } noraise {
    _ => fail("save unexpectedly replaced a different file version")
  }
}

///|
async test "editor save updates the loaded UTF8 version and truncates the old tail" {
  let dir = @fs.tmpdir(prefix="seekmoon-editor-save-")
  defer @fs.rmdir(dir, recursive=true)
  let target = @pathx.Path(dir).join("source.mbt").to_string()
  let original = "你好 🌙\r\nlong original tail\n"
  @fs.write_file(target, original, create_mode=CreateNew)
  let path = @pathx.Path(target).to_absolute().unwrap().to_uri_path().unwrap()
  let reply = write_file_op({
    session: "editor",
    root: None,
    path,
    content: "new\n",
    expected_content: Some(original),
  })
  assert_eq(reply.path, path)
  assert_eq(@fs.read_file(target).text(), "new\n")
}

///|
async test "editor save refuses stale and removed loaded files" {
  let dir = @fs.tmpdir(prefix="seekmoon-editor-conflict-")
  defer @fs.rmdir(dir, recursive=true)
  let target = @pathx.Path(dir).join("source.mbt").to_string()
  let path = @pathx.Path(target).to_absolute().unwrap().to_uri_path().unwrap()
  @fs.write_file(target, "external change", create_mode=CreateNew)
  let payload : @protocol.WriteFilePayload = {
    session: "editor",
    root: None,
    path,
    content: "edited",
    expected_content: Some("loaded version"),
  }
  expect_editor_save_conflict(payload)
  assert_eq(@fs.read_file(target).text(), "external change")
  @fs.remove(target)
  expect_editor_save_conflict(payload)
  assert_true(!@fs.exists(target))
}

///|
async test "editor create is exclusive and does not replace an existing file" {
  let dir = @fs.tmpdir(prefix="seekmoon-editor-create-")
  defer @fs.rmdir(dir, recursive=true)
  let root = @pathx.Path(dir).to_absolute().unwrap().to_uri_path().unwrap()
  let payload : @protocol.WriteFilePayload = {
    session: "editor",
    root: Some(root),
    path: "new.txt",
    content: "first",
    expected_content: None,
  }
  let reply = write_file_op(payload)
  assert_eq(reply.path, root + "/new.txt")
  expect_editor_save_conflict({ ..payload, content: "replacement", })
  assert_eq(
    @fs.read_file(@pathx.Path(dir).join("new.txt").to_string()).text(),
    "first",
  )
}

///|
async test "editor save shares read_file absolute and relative address rules" {
  let dir = @fs.tmpdir(prefix="seekmoon-editor-path-")
  defer @fs.rmdir(dir, recursive=true)
  @fs.mkdir(@pathx.Path(dir).join("nested").to_string())
  let root = @pathx.Path(dir)
    .join("nested")
    .to_absolute()
    .unwrap()
    .to_uri_path()
    .unwrap()
  // fs.read_file explicitly retains ordinary relative .. meaning; saves must
  // address the same resource rather than invent a different containment rule.
  let reply = write_file_op({
    session: "editor",
    root: Some(root),
    path: "../sibling.txt",
    content: "outside nested",
    expected_content: None,
  })
  let read = read_file_op({ root: Some(root), path: "../sibling.txt", })
  guard read is Content(content~, absolute~, ..) else {
    fail("saved path did not read back as text")
  }
  assert_eq(content, "outside nested")
  assert_eq(absolute, reply.path)
  for
    payload in [
      @protocol.WriteFilePayload::{
        session: "editor",
        root: None,
        path: "relative.txt",
        content: "x",
        expected_content: None,
      },
      {
        session: "editor",
        root: Some(root),
        path: reply.path,
        content: "x",
        expected_content: Some("outside nested"),
      },
    ] {
    try write_file_op(payload) catch {
      HostError(message) =>
        assert_true(
          message.contains("absolute") || message.contains("relative"),
        )
      error => raise error
    } noraise {
      _ => fail("invalid absolute/root-relative path pair was accepted")
    }
  }
}

///|
async test "two shared-server saves from one baseline cannot both win" {
  let dir = @fs.tmpdir(prefix="seekmoon-editor-concurrent-")
  defer @fs.rmdir(dir, recursive=true)
  let target = @pathx.Path(dir).join("source.txt").to_string()
  @fs.write_file(target, "baseline", create_mode=CreateNew)
  let path = @pathx.Path(target).to_absolute().unwrap().to_uri_path().unwrap()
  let saved = Ref(0)
  let conflicts = Ref(0)
  @async.with_task_group(group => {
    for content in ["first", "second"] {
      group.spawn_bg(() => {
        try
          write_file_op({
            session: content,
            root: None,
            path,
            content,
            expected_content: Some("baseline"),
          })
        catch {
          HostError(message) => {
            assert_true(message.contains("file changed on disk"))
            conflicts.val += 1
          }
          error => raise error
        } noraise {
          _ => saved.val += 1
        }
      })
    }
  })
  assert_eq(saved.val, 1)
  assert_eq(conflicts.val, 1)
  let content = @fs.read_file(target).text()
  assert_true(content == "first" || content == "second")
}

///|
#cfg(not(platform="windows"))
async test "editor saves follow the same symlink target as reads" {
  let dir = @fs.tmpdir(prefix="seekmoon-editor-link-")
  defer @fs.rmdir(dir, recursive=true)
  let target = @pathx.Path(dir).join("target.txt").to_string()
  let link = @pathx.Path(dir).join("link.txt").to_string()
  @fs.write_file(target, "old", create_mode=CreateNew)
  @fs.chmod(target, 0o755)
  @fs.symlink(link, target~)
  let path = @pathx.Path(link).to_absolute().unwrap().to_uri_path().unwrap()
  ignore(
    write_file_op({
      session: "editor",
      root: None,
      path,
      content: "new",
      expected_content: Some("old"),
    }),
  )
  assert_eq(@fs.read_file(target).text(), "new")
  assert_true(@fs.can_execute(target))
  assert_true(@fs.kind(link, follow_symlink=false) is SymLink)
}
