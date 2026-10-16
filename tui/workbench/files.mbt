///|
fn search(
  args : Array[String],
  context : Context,
  semantic~ : Bool,
) -> Plan raise InputError {
  let patterns : Array[String] = []
  let mut regex = false
  let mut case_sensitive = false
  let mut whole_word = false
  let mut include_glob = ""
  let mut exclude_glob = ""
  let mut index = 1
  while index < args.length() {
    let value = args[index]
    match value {
      "--regex" => regex = true
      "--case" => case_sensitive = true
      "--word" => whole_word = true
      "--include" => {
        index += 1
        include_glob = arg(
          args, index, "/grep QUERY [--include GLOB] [--exclude GLOB]",
        )
      }
      "--exclude" => {
        index += 1
        exclude_glob = arg(
          args, index, "/grep QUERY [--include GLOB] [--exclude GLOB]",
        )
      }
      _ => patterns.push(value)
    }
    index += 1
  }
  guard !patterns.is_empty() else {
    raise InputError(
      "Usage: /grep QUERY [--regex] [--case] [--word] [--include GLOB] [--exclude GLOB] | /semantic PATTERN",
    )
  }
  let root = workspace(context)
  if semantic {
    request(
      @commands.fs_search_semantic,
      {
        root,
        patterns,
        include_glob,
        exclude_glob,
        session_key: "seekmoon-tui-semantic",
        generation: next_search_generation(),
        max_results: 1000,
      },
      "Structural search",
    )
  } else {
    request(
      @commands.fs_search_text,
      {
        root,
        query: patterns.join(" "),
        regex,
        case_sensitive,
        whole_word,
        include_glob,
        exclude_glob,
        session_key: "seekmoon-tui-grep",
        generation: next_search_generation(),
        max_results: 1000,
      },
      "Text search",
    )
  }
}

///|
fn navigation(
  command : String,
  args : Array[String],
  context : Context,
) -> Plan raise InputError {
  let payload : @protocol.MoonIdeNavigationPayload = {
    session: context.session,
    root: workspace(context),
    path: arg(args, 1, "/definition|references PATH LINE COLUMN"),
    line: positive(
      arg(args, 2, "/definition|references PATH LINE COLUMN"),
      "Line",
    ),
    column: positive(
      arg(args, 3, "/definition|references PATH LINE COLUMN"),
      "Column",
    ),
  }
  if command == "/definition" {
    request(@commands.moonide_definition, payload, "Definition")
  } else {
    request(@commands.moonide_references, payload, "References")
  }
}

///|
fn git(args : Array[String], context : Context) -> Plan raise InputError {
  match args.get(1).unwrap_or("changes") {
    "branch" =>
      request(
        @commands.git_branch,
        {
          session: context.session,
          cwd: context.workspace,
          base_hint: args.get(2),
        },
        "Current branch",
      )
    "pr" =>
      request(
        @commands.git_pull_request,
        { session: context.session, cwd: context.workspace, branch_hint: None, },
        "Current pull request",
      )
    "changes" =>
      request(
        @commands.git_changes,
        { session: context.session, workspace: context.workspace, },
        "Review changes",
      )
    "commit" =>
      request(
        @commands.git_commit_changes,
        {
          session: context.session,
          workspace: context.workspace,
          commit: arg(args, 2, "/git commit REVISION"),
        },
        "Commit changes",
      )
    "original" =>
      request(
        @commands.git_original_file,
        {
          session: context.session,
          workspace: context.workspace,
          path: arg(args, 2, "/git original PATH [REVISION]"),
          revision: args.get(3),
        },
        "Original file",
      )
    _ =>
      raise InputError(
        "Usage: /git changes|branch [BASE]|pr|commit REVISION|original PATH [REVISION]",
      )
  }
}

///|
fn diff_plan(args : Array[String], context : Context) -> Plan raise InputError {
  let path = arg(args, 1, "/diff PATH [REVISION]")
  let payload : @protocol.GitOriginalFilePayload = {
    session: context.session,
    workspace: context.workspace,
    path,
    revision: args.get(2),
  }
  {
    title: "Diff · " + path,
    method_: @commands.git_original_file.name(),
    payload: payload.to_json(),
    refresh: false,
    perform: client => {
      let changes = client.call(@commands.git_changes, {
        session: context.session,
        workspace: context.workspace,
      })
      let change = changes.changes
        .iter()
        .find_first(change => change.path == path)
      let revision = if payload.revision is Some(revision) {
        Some(revision)
      } else if changes.baseline is Some(revision) {
        Some(revision)
      } else {
        changes.head
      }
      let original_path = change
        .bind(change => change.original_path)
        .unwrap_or(path)
      let original = client.call(@commands.git_original_file, {
        ..payload,
        path: original_path,
        revision,
      })
      let before = match original {
        @protocol.Missing => ""
        @protocol.OriginalContent(content) => content
        @protocol.BinaryOriginal =>
          raise InputError("The original file is binary")
        @protocol.OversizedOriginal =>
          raise InputError("The original file is too large to preview")
      }
      let after = if change is Some({ kind: "deleted", .. }) {
        ""
      } else {
        let root = checkout_root(client, context)
        let current = client.call(@commands.fs_read_file, {
          path,
          root: Some(root),
        })
        match current {
          @protocol.Content(content~, ..) => content
          @protocol.Binary | @protocol.BinaryContent(..) =>
            raise InputError("The current file is binary")
          @protocol.Oversized =>
            raise InputError("The current file is too large to preview")
        }
      }
      Json(line_diff(before, after))
    },
  }
}

///|
/// A bounded line diff uses common prefix/suffix trimming. Changed regions
/// retain every removed/added line, including Unicode text and empty lines.
pub fn line_diff(before : String, after : String) -> Array[String] {
  let left = if before.is_empty() { [] } else { before.split("\n").collect() }
  let right = if after.is_empty() { [] } else { after.split("\n").collect() }
  let mut start = 0
  while start < left.length() &&
        start < right.length() &&
        left[start] == right[start] {
    start += 1
  }
  if start == left.length() && start == right.length() {
    return ["No changes."]
  }
  let mut left_end = left.length()
  let mut right_end = right.length()
  while left_end > start &&
        right_end > start &&
        left[left_end - 1] == right[right_end - 1] {
    left_end -= 1
    right_end -= 1
  }
  let result = [
    "--- original",
    "+++ working tree",
    "@@ -\{start + 1},\{left_end - start} +\{start + 1},\{right_end - start} @@",
  ]
  for line in left.exact_view(start=(start - 3).max(0), end=start) {
    result.push(" " + line.to_owned())
  }
  for line in left.exact_view(start~, end=left_end) {
    result.push("-" + line.to_owned())
  }
  for line in right.exact_view(start~, end=right_end) {
    result.push("+" + line.to_owned())
  }
  for
    line in right.exact_view(
      start=right_end,
      end=(right_end + 3).min(right.length()),
    ) {
    result.push(" " + line.to_owned())
  }
  result
}
