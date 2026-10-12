// The MCP server configuration every serve engine is spawned with: one
// user-level file beside the global session store, in the de-facto
// `{"mcpServers": {...}}` shape the engine's `--mcp-config` decodes. The
// host never interprets it — the engine connects the servers and reports
// what it could not use — so the host's part is naming the file and noticing
// that it changed.

///|
/// Where the desktop looks for the user's MCP server configuration, or
/// `None` when the host has no home directory to look in. The user writes
/// the file by hand; the host only reads it.
fn mcp_config_path() -> @pathx.Absolute? {
  guard @workspaces.global_store_root() is Some(root) else { return None }
  Some(root.join("mcp.json"))
}

///|
/// What the host observed in the configuration file when it resolved a run's
/// config. A file that exists but cannot be read is its own observation, not
/// an absent one: the engine is still pointed at it and reports the failure.
priv enum McpConfigRevision {
  /// The SHA-256 of the file's content, in hex. A live engine keeps its
  /// config for its whole life, so what is kept of the file must not grow
  /// with the file.
  Digest(String)
  ReadFailed(String)
}

///|
/// The revision of a file holding `text`.
fn McpConfigRevision::of_text(text : String) -> McpConfigRevision {
  Digest(@crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(text))))
}

///|
/// The MCP configuration file a serve engine is pointed at.
priv struct McpConfig {
  path : @pathx.Absolute
  // Pins the engine process to what the file held (see `engine_fingerprint`):
  // servers are connected once at engine startup, so an edit only takes
  // effect in a new process.
  revision : McpConfigRevision
}

///|
/// The configuration the next engine should load. An absent file is the
/// ordinary unconfigured state and names nothing, which leaves an
/// `OPENSEEK_MCP_CONFIG` inherited from the launching shell in effect exactly
/// as it is for the CLI.
async fn resolved_mcp_config() -> McpConfig? {
  guard mcp_config_path() is Some(path) else { return None }
  let text = @fsx.read_text_if_exists(path.to_path()) catch {
    error if @async.is_being_cancelled() => raise error
    error => return Some({ path, revision: ReadFailed("\{error}"), })
  }
  guard text is Some(text) else { return None }
  Some({ path, revision: McpConfigRevision::of_text(text), })
}

///|
/// The fingerprint component for a run's MCP configuration. The tags keep a
/// read failure from ever colliding with a digest of the same text.
fn mcp_config_fingerprint(config : McpConfig?) -> String {
  guard config is Some({ path, revision, }) else { return "none" }
  match revision {
    Digest(digest) => "sha256\u{1}\{path}\u{1}\{digest}"
    ReadFailed(error) => "unreadable\u{1}\{path}\u{1}\{error}"
  }
}

///|
async test "an absent MCP configuration names nothing; a present one pins its text" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var(test_home_env_name())
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-config-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  set_test_home(root.to_string())
  assert_true(resolved_mcp_config() is None)
  guard mcp_config_path() is Some(path) else {
    fail("a home directory should place the MCP configuration")
  }
  assert_eq(path.to_string(), root.join(".openseek/mcp.json").to_string())
  @fsx.ensure_dir(path.to_path().dirname())
  @fsx.write_text(path.to_path(), "{\"mcpServers\": {}}")
  guard resolved_mcp_config() is Some(empty) else {
    fail("an existing MCP configuration should be resolved")
  }
  assert_true(empty.path == path)
  // What is kept of the file is a fixed-size digest of it, not its text.
  guard empty.revision is Digest(digest) else {
    fail("a readable file is observed by its digest")
  }
  assert_eq(digest.length(), 64)
  assert_true(
    mcp_config_fingerprint(Some(empty)) ==
    mcp_config_fingerprint(
      Some({
        ..empty,
        revision: McpConfigRevision::of_text("{\"mcpServers\": {}}"),
      }),
    ),
  )
  @fsx.write_text(
    path.to_path(),
    "{\"mcpServers\": {\"a\": {\"command\": \"a\"}}}",
  )
  let edited = resolved_mcp_config()
  assert_true(
    mcp_config_fingerprint(Some(empty)) != mcp_config_fingerprint(edited),
  )
  assert_true(mcp_config_fingerprint(None) != mcp_config_fingerprint(edited))
}

///|
async test "an unreadable MCP configuration is carried, not treated as absent" {
  ambient_env_test_lock.acquire()
  defer ambient_env_test_lock.release()
  let previous_home = @sys.get_env_var(test_home_env_name())
  defer restore_home_env(previous_home)
  let root : @pathx.Path = Path(
    @fs.realpath(@fs.tmpdir(prefix="openseek-mcp-config-unreadable-")),
  )
  defer @fs.rmdir(root.to_string(), recursive=true)
  set_test_home(root.to_string())
  // A directory where the file belongs exists but can never be read as one,
  // on every platform and regardless of the user's permissions.
  @fsx.ensure_dir(root.join(".openseek/mcp.json"))
  guard resolved_mcp_config() is Some(config) else {
    fail("a configuration that exists but cannot be read must not be dropped")
  }
  assert_true(config.revision is ReadFailed(_))
  assert_true(
    mcp_config_fingerprint(Some(config)) !=
    mcp_config_fingerprint(
      Some({ ..config, revision: McpConfigRevision::of_text(""), }),
    ),
  )
}
