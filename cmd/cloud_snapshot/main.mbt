///|
async fn main {
  try {
    let request = @json.parse(@stdio.stdin.read_all().text())
    @stdio.stdout.write(@cloud_export.render(request).stringify() + "\n")
  } catch {
    error => {
      @stdio.stderr.write("cloud_snapshot: \{error}\n") catch {
        _ => ()
      }
      @sys.exit(1)
    }
  }
}
