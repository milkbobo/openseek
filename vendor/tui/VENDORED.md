# Vendored tui

Source: `/home/tonyfettes/projects/tui`

Commit: `dac0c458a619587c6edc9c9bd90423128c4567a3` (clean working tree).

License: Apache-2.0; see [LICENSE](LICENSE).

The library sources and tests are copied verbatim. Build output, Git metadata,
project-specific agent instructions, upstream reference checkouts, examples,
benchmarks, and development documentation are omitted.

Local changes:

- Added the Apache-2.0 license text declared by the upstream manifest.
- Added `Size(width~, height~)` so clients can construct sizes for pure views
  and rendering tests. The fields remain read-only outside the library.
- Added `Editor(preserve_text=true)` for file editors to preserve tabs, CRLF,
  and other source text while retaining the existing composer defaults.
