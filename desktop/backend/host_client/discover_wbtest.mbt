///|
async test "SSH discovery uses setup installation or PATH and rejects missing incompatible or failed CLI" {
  let root = @fs.tmpdir(prefix="ssh-cli-discovery-")
  defer @fs.rmdir(root, recursive=true)
  let home = root + "/home with spaces"
  let installed = home + "/.openseek/bin/openseek"
  let path_cli = root + "/bin/openseek"
  @fs.mkdir(home + "/.openseek/bin", recursive=true)
  @fs.mkdir(root + "/bin")
  let login = root + "/login"
  @fs.write_file(login, "#!/bin/sh\nexec /bin/sh -c \"$4\"\n")
  @fs.chmod(login, 0o700)
  let ssh = root + "/ssh"
  @fs.write_file(
    ssh,
    "#!/bin/sh\nexport HOME=" +
    @ssh_shell.quote(home) +
    " SHELL=" +
    @ssh_shell.quote(login) +
    " PATH=" +
    @ssh_shell.quote(root + "/bin:/usr/bin:/bin") +
    "\nfor command do :; done\nexec /bin/sh -c \"$command\"\n",
  )
  @fs.chmod(ssh, 0o700)
  async fn cli(path : String, protocol : Int32, code : Int32) -> Unit {
    let info : Json = {
      "launcher": path,
      "build_id": "test-cli",
      "data_dir": home + "/data",
      "protocol_version": protocol,
    }
    @fs.write_file(
      path,
      "#!/bin/sh\n[ \"$1 $2\" = 'app-server info' ] || exit 19\nprintf '%s\\n' " +
      @ssh_shell.quote(info.stringify()) +
      "\nexit " +
      code.to_string() +
      "\n",
    )
    @fs.chmod(path, 0o700)
  }
  cli(installed, 1, 0)
  cli(path_cli, 1, 0)
  let (launcher, build, data) = discover("test-host", ssh~)
  assert_eq(launcher, installed)
  assert_eq(build, "test-cli")
  assert_eq(data, home + "/data")
  @fs.remove(installed)
  let (launcher, _, _) = discover("test-host", ssh~)
  assert_eq(launcher, path_cli)
  for (protocol, code) in [(2, 0), (1, 17)] {
    cli(path_cli, protocol, code)
    let rejected = try {
      ignore(discover("test-host", ssh~))
      false
    } catch {
      HostClientError(_) => true
      error => raise error
    }
    assert_true(rejected)
  }
  @fs.remove(path_cli)
  let message = try {
    ignore(discover("test-host", ssh~))
    "unexpected success"
  } catch {
    HostClientError(message) => message
    error => raise error
  }
  assert_true(message.contains("openseek setup"))
}
