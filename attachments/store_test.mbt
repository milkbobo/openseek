///|
async test "immutable images deduplicate across writers and verify missing or corrupt bytes" {
  let home = @fs.tmpdir(prefix="openseek-attachments-")
  defer @fs.rmdir(home, recursive=true)
  let image = @protocol.Image::from_bytes(b"\x89PNG\r\n\x1a\noriginal")
  @async.with_task_group() <| group => {
    let first = group.spawn(() => @attachments.save(image, home~))
    let second = group.spawn(() => @attachments.save(image, home~))
    let reference = first.wait()
    assert_eq(reference, second.wait())
    assert_eq(@attachments.read(reference, home~), image)
    let content : @protocol.Content = Content([
      Text("before"),
      Image(image),
      Text("after"),
      Image(image),
    ])
    let persisted = @attachments.admit(content, home~)
    assert_true(
      persisted.0 is [Text("before"), ImageRef(a), Text("after"), ImageRef(b)] &&
      a == b,
    )
    assert_eq(@attachments.restore(persisted, home~), content)
    let path = @attachments.path(reference, home~)
    @fs.write_file(
      path,
      b"\x89PNG\r\n\x1a\nmodified",
      create_mode=CreateOrTruncate,
    )
    try @attachments.read(reference, home~) catch {
      error => assert_true("\{error}".contains("digest mismatch"))
    } noraise {
      _ => fail("corrupt image was accepted")
    }
    @fs.remove(path)
    try @attachments.read(reference, home~) catch {
      _ => ()
    } noraise {
      _ => fail("missing image was accepted")
    }
  }
}
