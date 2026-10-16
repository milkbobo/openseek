///|
test "SSH operation preserves failure diagnostics and completed values" {
  let reply : @protocol.SshOperation[@protocol.SshProfileTarget] = @json.from_json({
      "status": "failed",
      "message": "Permission denied",
      "extra": true,
    },
  )
  assert_true(reply is SshFailed("Permission denied"))
  let reply : @protocol.SshOperation[@protocol.SshProfileTarget] = @json.from_json({
      "status": "completed",
      "value": { "id": "ssh_host" },
    },
  )
  assert_true(reply is SshCompleted({ id: "ssh_host", }))
}
