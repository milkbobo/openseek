# Vendored ghostty

Source: `/home/tonyfettes/projects/ghostty`

Commit: `ddbbb98e941c34078f0f96cd736ac9d9ade6ca19` (clean working tree).

License: Apache-2.0; see [LICENSE](LICENSE).

The library sources and tests are copied from that commit. Build output, Git metadata,
project-specific agent instructions, upstream reference checkouts, examples,
benchmarks, and development documentation are omitted.

Local changes:

- Removed the deprecated manifest `exclude` option for the omitted `upstream`
  directory and the `lexmatch_longest_match` warning flag, which this workspace's
  compiler does not recognize.
- Added explicit trait method exports in `extends.mbt` files, with `core/debug`
  imports, to preserve upstream method lookup under the current compiler.
- Migrated the parser's indexing operator to the current `#alias` declaration
  and removed unused parser/test imports.
- Qualified package references in black-box tests and disambiguated one empty
  benchmark map for the current compiler's warning checks.

These compatibility changes preserve parser and terminal behavior.
