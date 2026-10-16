///|
/// Identity and paths of the working host. The desktop resolves its bundle;
/// the daemon will resolve its installed build. Shared handlers do neither.
pub(all) struct HostConfig {
  data_dir : @pathx.Path
  engine_executable : String
  codex : @codex.CodexSettings
  resources : @host.HostResources
}

///|
/// Prepare required persistent state without silently falling back to another
/// directory. Embedders call this before starting the service's pumps.
pub async fn ApiState::prepare(self : ApiState) -> Unit {
  guard self.config.data_dir.is_host_absolute() else {
    raise @host.HostError("Host data directory must be absolute")
  }
  let dir = self.config.data_dir.to_string()
  @fs.mkdir(dir, recursive=true) catch {
    @os_error.OSError(_) as error if error.is_EEXIST() => {
      guard @fs.kind(dir) is Directory else { raise error }
    }
    error => raise error
  }
}

///|
fn test_service() -> ApiState {
  ApiState({
    data_dir: Path("/unused-test-host"),
    engine_executable: "unused",
    codex: @codex.CodexSettings::default(),
    resources: @host.HostResources::from_path(),
  })
}
