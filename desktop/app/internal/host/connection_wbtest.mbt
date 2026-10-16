///|
#cfg(not(platform="windows"))
async test "desktop connection forwards terminal bytes and closes its child" {
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      let connection = HostConnection()
      let events : @async.Queue[@protocol.Notification] = Queue(
        kind=Blocking(8),
      )
      let pump = group.spawn(() => {
        connection.run(event => events.put(event), _ => ())
      })
      let id = @terminal.open_terminal(
        connection.terminal,
        cwd="/tmp",
        cols=80,
        rows=24,
        command=["/bin/sh", "-c", "printf X; exec /bin/cat"],
      )
      guard events.get() is TerminalOutput(event) else {
        fail("missing terminal output")
      }
      assert_eq(event.id, id)
      assert_eq(event.sequence, 1)
      assert_eq(@base64.decode(event.data), b"X")
      connection.close_terminals()
      guard events.get() is TerminalExit(event) else {
        fail("missing terminal exit after close")
      }
      assert_eq(event.id, id)
      pump.cancel()
      pump.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
    })
  })
}
