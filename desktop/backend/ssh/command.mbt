///|
pub(all) suberror SshError {
  SshError(String)
}

///|
pub fn arguments(command : String) -> Array[String] raise {
  let options = @protocol.ssh_connection_arguments(command) catch {
    @protocol.SshCommandError(message) => raise SshError(message)
    error => raise error
  }
  [
    "-T", "-oControlMaster=no", "-oControlPath=none", "-oRemoteCommand=none", "-oRequestTTY=no",
    "-oBatchMode=yes", "-oConnectTimeout=15", "-oServerAliveInterval=15", "-oServerAliveCountMax=2",
    ..options,
  ]
}

///|
fn remote_command(server : String) -> String raise {
  guard !server.is_empty() && !server.contains("\n") else {
    raise SshError("Missing remote app-server executable")
  }
  if server == "openseek" {
    match @env.get_env_var("SEEKMOON_SSH_RELEASE_URL") {
      Some(url) => prepare_command(url, "=https,http,file")
      None =>
        prepare_command(
          "https://cli.moonbitlang.com/openseek/cli/releases/v" + CliRelease,
          "=https",
        )
    }
  } else {
    "exec " + shell_quote(server) + " app-server"
  }
}
