# Cloud snapshot helper

This command converts captured visible Cloud messages into a standalone HTML
snapshot and its downloadable JSON dataset. It reuses `viz_export` through the
pure `viz_export/cloud` package. It does not call a model, read files, or use the
network.

## Build and run

Build the helper as WASI linear-memory Wasm (`--target wasm`, not `wasm-gc`)
and build the matching visualizer assets from the same checkout:

```sh
moon build cmd/cloud_snapshot --target wasm --release
moon build cmd/viz_app --target js --release
```

The build inputs and outputs are:

| Artifact | Path |
|---|---|
| Helper | `_build/wasm/release/build/moonbitlang/openseek/cmd/cloud_snapshot/cloud_snapshot.wasm` |
| Visualizer shell | `web/index.html` |
| Visualizer bundle | `_build/js/release/build/moonbitlang/openseek-viz-app/openseek-viz-app.js` |

Run the compiled module with `moonrun` or a compatible host with stdin, stdout,
and stderr. Stdin is one UTF-8 JSON object, read to EOF:

```json
{"session_id":"session-id","title":"Conversation","messages":[{"kind":"user","data":{"content":"Hello"},"created_at":100}],"shell_html":"<html><script src=\"/viz_app.js\"></script></html>","bundle_js":"/* compiled viz_app */"}
```

The host reads the fixed visualizer assets and supplies their text. `messages`
is the captured `/messages` visible-history projection. Each message requires
`kind`, `data`, and numeric `created_at`; extra metadata is ignored. This is
not the model's internal session/checkpoint history.

Stdout is one UTF-8 JSON object `{html: String, json: String}` plus a newline.
`json` is the complete downloadable visualizer dataset, exactly the data
embedded in `html`. Stderr contains diagnostics; a nonzero exit means failure.
No share-operation state, output files, or recovery cache is created. Packaging,
publishing, downloading, and service integration are outside this command.

## Verify

The pure package tests run on native, Wasm, and JS:

```sh
moon test viz_export/cloud --target native
moon test viz_export/cloud --target wasm
moon test viz_export/cloud --target js
```

The minimal golden input and output are in `fixtures/input.json` and
`fixtures/output.json`. Verify the prebuilt module without rebuilding it:

```sh
moonrun _build/wasm/release/build/moonbitlang/openseek/cmd/cloud_snapshot/cloud_snapshot.wasm < cmd/cloud_snapshot/fixtures/input.json > /tmp/cloud-snapshot-output.json
cmp cmd/cloud_snapshot/fixtures/output.json /tmp/cloud-snapshot-output.json
```
