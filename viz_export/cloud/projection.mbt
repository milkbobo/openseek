///|
/// Normalize a visible Cloud message into the standalone visualizer item format.
pub fn normalized_item(kind : String, data : Json) -> Json? {
  match kind {
    "user" | "tool_result" => Some({ "kind": Json(kind), "payload": data })
    "assistant_message" => {
      // The visualizer's durable AssistantMessage requires tool_calls.
      let payload = match data {
        Object(fields) if fields.get("tool_calls") is None => {
          let fields = fields.copy()
          fields["tool_calls"] = Json::array([])
          Json(fields)
        }
        _ => data
      }
      Some({ "kind": "assistant", "payload": payload })
    }
    "tool_call" => {
      let call : Json = match data {
        {
          "id": String(id),
          "function": {
            "name": String(name),
            "arguments": String(arguments),
            ..
          },
          ..
        } =>
          { "id": Json(id), "name": Json(name), "arguments": Json(arguments) }
        _ => data
      }
      Some({
        "kind": "assistant",
        "payload": { "content": "", "tool_calls": [call] },
      })
    }
    "task_finished" =>
      match data {
        {
          "status": "completed",
          "result": { "output": { "answer": String(answer), .. }, .. },
          ..
        } =>
          Some({
            "kind": "terminal",
            "payload": { "kind": "finished", "message": Json(answer) },
          })
        _ => None
      }
    _ => None
  }
}

///|
/// Encode one visible Cloud message as the existing standalone JSONL envelope.
pub fn envelope(
  sequence : Int32,
  kind : String,
  data : Json,
  created_at : Double,
) -> Json {
  let item : Json = normalized_item(kind, data).unwrap_or_else(() => {
    if kind == "task_finished" {
      let completed = data is { "status": "completed", .. }
      {
        "kind": "terminal",
        "payload": {
          "kind": if completed {
            "finished"
          } else {
            "failed"
          },
          "message": if completed {
            ""
          } else {
            data.stringify()
          },
        },
      }
    } else {
      {
        "kind": "runtime_notice",
        "payload": { "content": kind + ": " + data.stringify() },
      }
    }
  })
  { "sequence": sequence, "ts": created_at, "item": item }
}
