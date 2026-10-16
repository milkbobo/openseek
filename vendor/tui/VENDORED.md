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
- Added opt-in `Frame(inherit_colors=true)` so text can retain painted panel
  colors instead of reverting to the outer terminal's default palette.
- Added optional `Editor.draw(line_style~)` to color zero-based source lines
  correctly across wrapping and scrolling, including duplicate line text.
- Added `Line.concat` to compose styled table cells and continuation prefixes
  without flattening text styles.
- Added `Scroll.hold` to keep the current viewport when expanding transcript
  details, instead of following the newly extended bottom.
- Added editor wheel browsing independent of the caret, including the line-number
  gutter. Edits and cursor navigation resume caret tracking. `Layout.cursor` is
  optional when wheel browsing has moved the caret outside the viewport.
