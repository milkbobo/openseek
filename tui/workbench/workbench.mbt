///|
/// The selected conversation supplies authority and default scope for commands.
pub(all) struct Context {
  session : String
  codex_thread : String?
  workspace : String?
  model : String
  run_id : String?
  archived : Bool
}

///|
pub struct Output {
  title : String
  lines : Array[String]
  refresh : Bool
}

///|
pub(all) suberror InputError {
  InputError(String)
} derive(Debug)

///|
/// Payload and reply types are captured together before type erasure, exactly
/// as the server's endpoint catalog does. A command cannot decode another
/// command's reply accidentally.
struct Plan {
  title : String
  method_ : String
  payload : Json
  refresh : Bool
  perform : async (@client.Client) -> Json
}

///|
pub fn Plan::command_name(self : Plan) -> String {
  self.method_
}

///|
pub fn Plan::params(self : Plan) -> Json {
  self.payload
}

///|
fn[Payload : ToJson, Reply : @json.FromJson + ToJson] request(
  command : @commands.Command[Payload, Reply],
  payload : Payload,
  title : String,
  refresh~ : Bool = false,
) -> Plan {
  {
    title,
    method_: command.name(),
    payload: payload.to_json(),
    refresh,
    perform: client => {
      let reply : Reply = client.call(command, payload)
      ToJson::to_json(reply)
    },
  }
}

///|
/// Execute a discoverable desktop operation using the same typed command
/// catalog as Proton. Operational errors retain their original error channel.
pub async fn execute(
  client : @client.Client,
  text : String,
  context : Context,
) -> Output {
  let tokens = words(text)
  let command = tokens.get(0).unwrap_or("")
  let context = match command {
    "/file" | "/read" | "/files" if tokens
      .get(1)
      .map(path => path.has_prefix("/"))
      .unwrap_or(false) => context
    "/files"
    | "/file"
    | "/read"
    | "/find"
    | "/grep"
    | "/semantic"
    | "/definition"
    | "/references"
    | "/symbols"
    | "/diagnostics"
    | "/hover"
    | "/packages" =>
      { ..context, workspace: Some(checkout_root(client, context)), }
    _ => context
  }
  let operation = plan(text, context)
  let reply = (operation.perform)(client)
  { title: operation.title, lines: display(reply), refresh: operation.refresh, }
}

///|
/// Shell-style tokenization supports quoted paths and messages without
/// executing any shell expansion. Backslashes are literal inside single quotes.
pub fn arguments(text : String) -> Array[String] raise InputError {
  words(text)
}

///|
fn words(text : String) -> Array[String] raise InputError {
  let result : Array[String] = []
  let mut word = ""
  let mut quote : Char? = None
  let mut escape = false
  let mut started = false
  for ch in text {
    if escape {
      word += ch.to_string()
      escape = false
    } else if ch == '\\' && quote != Some('\'') {
      escape = true
      started = true
    } else if quote is Some(mark) {
      if ch == mark {
        quote = None
      } else {
        word += ch.to_string()
      }
    } else if ch == '\'' || ch == '"' {
      quote = Some(ch)
      started = true
    } else if ch is (' ' | '\t' | '\n' | '\r') {
      if started {
        result.push(word)
        word = ""
        started = false
      }
    } else {
      word += ch.to_string()
      started = true
    }
  }
  guard quote is None && !escape else {
    raise InputError(
      "Unfinished quote or escape; quote paths or text containing spaces.",
    )
  }
  if started {
    result.push(word)
  }
  result
}

///|
fn arg(
  args : Array[String],
  index : Int32,
  usage : String,
) -> String raise InputError {
  guard args.get(index) is Some(value) && !value.is_empty() else {
    raise InputError("Usage: " + usage)
  }
  value
}

///|
fn rest(
  args : Array[String],
  index : Int32,
  usage : String,
) -> String raise InputError {
  let value = args.exact_view(start=index.min(args.length())).join(" ")
  guard !value.is_empty() else { raise InputError("Usage: " + usage) }
  value
}

///|
fn number(value : String, label : String) -> Int32 raise InputError {
  @string.parse_int(value) catch {
    _ => raise InputError(label + " must be an integer")
  }
}

///|
fn positive(value : String, label : String) -> Int32 raise InputError {
  let value = number(value, label)
  guard value > 0 else { raise InputError(label + " must be positive") }
  value
}

///|
fn boolean(value : String) -> Bool raise InputError {
  match value {
    "on" | "true" => true
    "off" | "false" => false
    _ => raise InputError("Expected on or off")
  }
}

///|
fn workspace(context : Context) -> String raise InputError {
  guard context.workspace is Some(path) && !path.is_blank() else {
    raise InputError("Select a workspace with /workspace PATH first.")
  }
  path
}

///|
fn job_scope(context : Context) -> @protocol.JobsScope {
  {
    session: context.session,
    workspace: context.workspace,
    archived: context.archived,
  }
}

///|
fn settings_patch() -> @protocol.SettingsSetPayload {
  {
    provider: None,
    custom_api_url: None,
    deepseek_api_key: None,
    glm_api_key: None,
    custom_api_key: None,
    followup_behavior: None,
  }
}

///|
/// Convert typed replies into a readable outline. Long content values retain
/// their lines, so source files, skill instructions and job logs remain useful.
pub fn display(value : Json) -> Array[String] {
  let lines : Array[String] = []
  render(value, "", lines)
  if lines.is_empty() {
    ["Done."]
  } else {
    lines
  }
}

///|
fn render(value : Json, prefix : String, lines : Array[String]) -> Unit {
  match value {
    Null => ()
    String(value) => {
      let mut first = true
      for line in value.split("\n") {
        lines.push((if first { prefix } else { "  " }) + line.to_owned())
        first = false
      }
    }
    Number(_, ..) | True | False => lines.push(prefix + value.stringify())
    Array(items) =>
      for index, item in items {
        render(item, "\{index + 1}. ", lines)
      }
    Object(fields) =>
      for key, field in fields {
        let label = key.split("_").join(" ")
        match field {
          Object(_) | Array(_) => {
            lines.push(prefix + label + ":")
            render(field, "  ", lines)
          }
          _ => render(field, prefix + label + ": ", lines)
        }
      }
  }
}

///|
pub extend InputError with Debug::{to_repr}

///|
let search_counter : Ref[Int32] = Ref(0)

///|
fn next_search_generation() -> Int32 {
  search_counter.val += 1
  search_counter.val
}

///|
async fn checkout_root(client : @client.Client, context : Context) -> String {
  let root = workspace(context)
  let reply = client.call(@commands.worktree_list, { workspace: root, })
  if reply.worktrees
    .iter()
    .find_first(tree => {
      if context.codex_thread is Some(id) {
        tree.codex_thread == Some(id)
      } else {
        tree.sessions.contains(context.session)
      }
    })
    is Some(tree) {
    guard tree.present else {
      raise InputError(
        "This conversation's worktree is missing. Use /worktree repair first.",
      )
    }
    tree.path
  } else {
    root
  }
}
