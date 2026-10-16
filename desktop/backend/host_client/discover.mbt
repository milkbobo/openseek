///|
/// Invoke the ordinary CLI installed by `openseek setup`, or on the login PATH.
/// Installation and upgrades belong to the CLI, never to the SSH transport.
pub async fn discover(
  destination : String,
  ssh~ : String = "/usr/bin/ssh",
) -> (String, String, String) {
  let result = command_reply(ssh, destination, "SSH CLI discovery", mark => {
    @ssh_shell.command(
      "printf '%s\\n' " +
      @ssh_shell.quote(mark) +
      "; " +
      (
        #|if [ -x "$HOME/.openseek/bin/openseek" ]; then cli="$HOME/.openseek/bin/openseek"; else cli=$(command -v openseek) || { echo 'Install the OpenSeek CLI release on this host and run openseek setup before connecting.' >&2; exit 127; }; fi; exec "$cli" app-server info
      ),
    )
  })
  guard result
    is {
      "launcher": String(launcher),
      "build_id": String(build_id),
      "data_dir": String(data_dir),
      "protocol_version": Number(version, ..),
      ..
    } &&
    launcher.has_prefix("/") &&
    data_dir.has_prefix("/") &&
    !build_id.is_blank() &&
    version == @host_control.ProtocolVersion.to_double() else {
    raise HostClientError(
      "Remote CLI does not support this SSH protocol; install a compatible OpenSeek CLI release and run openseek setup",
    )
  }
  (launcher, build_id, data_dir)
}
