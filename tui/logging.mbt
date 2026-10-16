///|
/// Configure logging before any backend service starts or the terminal enters
/// its alternate screen. Raw stdout writes would corrupt incremental drawing.
async fn configure_logging() -> Unit {
  let executable = @env.args().get(0).unwrap_or("seekmoon-tui")
  guard @backend_host.prepared_runtime_dir(executable) is Some(directory) else {
    fail("Cannot prepare the TUI log directory")
  }
  @xlog.global().set_handler(
    @xlog.File(directory.join("seekmoon-tui.log").to_string()),
  )
}
