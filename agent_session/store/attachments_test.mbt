///|
async test "new image events persist references and legacy migration preserves event identity" {
  let root = @fs.tmpdir(prefix="openseek-image-log-")
  defer @fs.rmdir(root, recursive=true)
  let store = @store.SessionStore(root, attachment_home=root + "/user")
  let image = @agent_session.Image::from_bytes(b"\x89PNG\r\n\x1a\nfixture")
  let original = @agent_session.Session(
    SessionId("legacy"),
    system_prompt="system",
  ).append(
    User(UserMessage(Content([Text("see"), Image(image)]))),
    unix_ms=1234,
  )
  store.create(original)
  let path = store.session_file(original.id())
  let stored = @fs.read_file(path).text()
  assert_true(stored.contains("attachment_id"))
  assert_false(stored.contains("\"data\":"))
  assert_true(
    @json.parse(stored.split("\n").collect()[0]) is { "version": 2, .. },
  )
  let loaded = store.load(original.id())
  assert_true(loaded.events()[0].item().has_image_refs())
  // Opening a legacy log is read-only; migration is explicit and idempotent.
  let legacy = "{\"version\":1,\"id\":\"legacy\",\"system_prompt\":\"system\"}\n" +
    Json(original.events()[0]).stringify() +
    "\n"
  @fs.write_file(path, legacy, create_mode=CreateOrTruncate)
  assert_eq(store.load(original.id()), original)
  assert_eq(@fs.read_file(path).text(), legacy)
  let migrated = store.migrate_images(original.id())
  assert_eq(migrated, loaded)
  assert_eq(store.migrate_images(original.id()), migrated)
  let extended = store.append(migrated, Terminal(Finished("done")))
  let fork = store.fork(extended.id(), SessionId("fork"), system_prompt="fork")
  assert_eq(fork.events()[0], migrated.events()[0])
  // A new store instance accepts the unchanged snapshot and appends references.
  let reopened = @store.SessionStore(root, attachment_home=root + "/user")
  let next = reopened.append(
    extended,
    User(UserMessage(Content([Image(image)]))),
  )
  assert_eq(reopened.load(next.id()), next)
}

///|
async test "first reference upgrades legacy bytes and returns exactly the committed snapshot" {
  let root = @fs.tmpdir(prefix="openseek-upgrade-image-")
  defer @fs.rmdir(root, recursive=true)
  let store = @store.SessionStore(root, attachment_home=root + "/user")
  let image = @agent_session.Image::from_bytes(b"GIF87a")
  let old = @agent_session.Session(SessionId("old"), system_prompt="s")
    .append(User(UserMessage(Content([Image(image)]))))
    .append(Terminal(Finished("done")))
  store.create(old)
  let path = store.session_file(old.id())
  @fs.write_file(
    path,
    "{\"version\":1,\"id\":\"old\",\"system_prompt\":\"s\"}\n" +
    Json(old.events()[0]).stringify() +
    "\n" +
    Json(old.events()[1]).stringify() +
    "\n",
    create_mode=CreateOrTruncate,
  )
  let loaded = store.load(old.id())
  let fork = store.fork(old.id(), SessionId("fork"), system_prompt="fork")
  assert_eq(store.load(fork.id()), fork)
  assert_true(fork.events()[0].item().has_image_refs())
  let next = store.append(loaded, User(UserMessage(Content([Image(image)]))))
  assert_eq(store.load(old.id()), next)
  assert_true(next.events()[0].item().has_image_refs())
  assert_true(next.events()[2].item().has_image_refs())
}
