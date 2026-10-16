///|
/// Invalid visible-history input; never fall back to an empty export.
pub(all) suberror SnapshotError {
  InvalidHistory(String)
}

///|
/// Render captured visible Cloud messages as standalone HTML and JSON.
/// Extra message metadata is ignored; kind, data and created_at are required.
pub fn render(request : Json) -> Json raise {
  guard request
    is {
      "shell_html": String(shell),
      "bundle_js": String(bundle),
      "session_id": String(session),
      "title": String(title),
      "messages": Array(messages),
      ..
    } else {
    raise InvalidHistory(
      "expected session_id, title, messages, shell_html and bundle_js",
    )
  }
  let events = StringBuilder()
  for index, message in messages {
    guard message
      is {
        "kind": String(kind),
        "data": data,
        "created_at": Number(created_at, ..),
        ..
      } else {
      raise InvalidHistory(
        "message \{index} requires kind, data and created_at",
      )
    }
    events.write_string(envelope(index + 1, kind, data, created_at).stringify())
    events.write_char('\n')
  }
  let exporter = @viz_export.StandaloneExport(shell, bundle)
  let json = exporter.json([
    Session(
      key="session-0",
      id=session,
      root="cloud://sessions/" + session,
      root_label="Cloud",
      is_marker=true,
      last_active=None,
      first_prompt=title,
      events=events.to_string(),
    ),
  ])
  { "html": exporter.render_json(json), "json": json }
}
