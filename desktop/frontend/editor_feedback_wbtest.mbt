///|
fn large_semantic_reference_for_test() -> @mention_context.SemanticSearchReference {
  let matches : Array[@protocol.SemanticSelectionMatch] = []
  for index in 0..<101 {
    matches.push({
      rule_id: "rule",
      description: Some("test rule"),
      file: "src/file-" + index.to_string() + ".mbt",
      start_line: 1,
      start_column: 1,
      end_line: 1,
      end_column: 8,
      matched_source: "inspect(value)",
    })
  }
  {
    id: "semantic-search-send-test",
    root: "/work",
    patterns: ["inspect($(x:arg))"],
    include_glob: "",
    exclude_glob: "",
    matches,
  }
}

///|
test "EditorCommentAdded attaches a deduplicated annotation chip" {
  let dispatch = test_dispatch()
  let model = test_model()
  let absolute = @interop.ChannelId::Local.test_resource(
    "/work/project/src/main.mbt",
  )
  // The chip path arrives workspace-relative from the panel (recorded when
  // the file was shown); the resource URI only routes the bubble removal.
  let msg : Msg = FileEditor(
    EditorCommentAdded(
      resource=@fileeditor.ModelUri::of(absolute),
      file=Relative("src/main.mbt"),
      range=@common.Range(5, 1, 6, 3),
      quote="fn parse_hover() {",
      comment="rename this",
      feedback_id="viewer-feedback-0",
    ),
  )
  let (_, next) = update(dispatch, msg, model)
  let mentions = next.active().mentions
  assert_eq(mentions.length(), 1)
  assert_true(
    mentions[0].ref_
    is Annotation(file="src/main.mbt", start_line=5, end_line=6, ..),
  )
  // Submitting the identical comment again is a no-op, not a second chip.
  let (_, again) = update(dispatch, msg, next)
  assert_eq(again.active().mentions.length(), 1)
}

///|
test "ApplyAllFeedback queues the attached annotation on a running task" {
  let dispatch = test_dispatch()
  let model = running_model()
  let (_, batched) = update(
    dispatch,
    FileEditor(
      EditorCommentAdded(
        resource=@fileeditor.ModelUri::of(
          @interop.ChannelId::Local.test_resource("/work/project/README.md"),
        ),
        file=Relative("README.md"),
        range=@common.Range(3, 1, 6, 46),
        quote="DeepSeek, Kimi, and Z.AI GLM models",
        comment="make this clearer",
        feedback_id="viewer-feedback-immediate",
      ),
    ),
    model,
  )
  assert_eq(batched.active().mentions.length(), 1)
  let (_, applied) = update(
    dispatch,
    FileEditor(@fileeditor.ApplyAllFeedback),
    batched,
  )
  assert_true(applied.active().mentions.is_empty())
  assert_eq(applied.active().pending_steers.length(), 1)
  let steer = applied.active().pending_steers[0]
  assert_eq(steer.mentions.length(), 1)
  // Clearing the active composer preserves the selection in the queued draft.
  assert_eq(batched.active().mentions, steer.mentions)
  assert_eq(
    steer.content,
    (
      #|<user_mentions>
      #|<annotation file="README.md" lines="3-6">
      #|<quote>
      #|DeepSeek, Kimi, and Z.AI GLM models
      #|</quote>
      #|<user_comment>
      #|make this clearer
      #|</user_comment>
      #|</annotation>
      #|</user_mentions>
    ),
  )
}

///|
test "DiffCommentAdded preserves modified and original-only line identity" {
  let dispatch = test_dispatch()
  let file = @pathx.Relative("src/main.mbt")
  let added : Msg = FileEditor(
    DiffCommentAdded(
      file~,
      original_line_number=None,
      modified_line_number=Some(7),
      quote="let answer = 42",
      comment="name this constant",
      resource=None,
      feedback_id=None,
    ),
  )
  let (_, with_added) = update(dispatch, added, test_model())
  let added_mentions = with_added.active().mentions
  assert_eq(added_mentions.length(), 1)
  assert_true(
    added_mentions[0].ref_
    is Annotation(
      file="src/main.mbt",
      start_line=7,
      end_line=7,
      quote="let answer = 42",
      comment="name this constant",
      side=@mention_context.WorkingRevision
    ),
  )
  assert_eq(added_mentions[0].range, Some(@common.Range(7, 1, 7, 16)))
  let deleted : Msg = FileEditor(
    DiffCommentAdded(
      file~,
      original_line_number=Some(3),
      modified_line_number=None,
      quote="obsolete()",
      comment="good removal",
      resource=None,
      feedback_id=None,
    ),
  )
  let (_, with_deleted) = update(dispatch, deleted, with_added)
  let deleted_mentions = with_deleted.active().mentions
  assert_eq(deleted_mentions.length(), 2)
  assert_true(
    deleted_mentions[1].ref_
    is Annotation(
      file="src/main.mbt",
      start_line=3,
      end_line=3,
      quote="obsolete()",
      comment="good removal",
      side=@mention_context.OriginalRevision
    ),
  )
  assert_eq(deleted_mentions[1].range, None)
}

///|
test "Codex original-side diff feedback queues in the Codex draft" {
  let dispatch = test_dispatch()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-original-feedback",
      "cwd": "/work/project",
      "preview": "Review",
      "turns": [
        { "id": "codex-turn-original", "status": "inProgress", "items": [] },
      ],
    },
  })
  let model = { ..test_model(), codex, screen: Codex, }
  let (_, batched) = update(
    dispatch,
    FileEditor(
      DiffCommentAdded(
        file=Relative("src/main.mbt"),
        original_line_number=Some(3),
        modified_line_number=None,
        quote="obsolete()",
        comment="keep this removal",
        resource=None,
        feedback_id=None,
      ),
    ),
    model,
  )
  assert_true(batched.active().mentions.is_empty())
  let draft = batched.codex_composer_input().draft
  assert_eq(draft.mentions.length(), 1)
  assert_true(
    draft.mentions[0].ref_
    is Annotation(
      file="src/main.mbt",
      start_line=3,
      end_line=3,
      quote="obsolete()",
      comment="keep this removal",
      side=@mention_context.OriginalRevision
    ),
  )
  assert_eq(draft.mentions[0].range, None)
  let (_, applied) = update(
    dispatch,
    FileEditor(@fileeditor.ApplyAllFeedback),
    batched,
  )
  let queued = applied.codex.transcript_items()
  assert_eq(queued.length(), 1)
  guard queued[0].kind is @transcript.User(content=prompt) else {
    fail("expected the queued feedback as a user prompt")
  }
  assert_true(prompt.contains("side=\"original\""))
  assert_true(prompt.contains("keep this removal"))
}

///|
test "original-revision diff comment chip does not navigate into the working file" {
  let dispatch = test_dispatch()
  let original_comment : Mention = {
    ref_: Annotation(
      file="src/main.mbt",
      start_line=3,
      end_line=3,
      quote="obsolete()",
      comment="good removal",
      side=@mention_context.OriginalRevision,
    ),
    range: None,
  }
  let (_, next) = update(
    dispatch,
    mention_opened(original_comment),
    test_model(),
  )
  assert_false(next.right_panel_open)
  assert_true(next.dock.active is None)
}

///|
test "Codex editor comments use annotation context, not textarea text or OpenSeek chat" {
  let dispatch = test_dispatch()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-1",
      "cwd": "/work/project",
      "preview": "Review",
      "turns": [],
    },
  })
  let model = { ..test_model(), codex, screen: Codex, }
  let msg : Msg = FileEditor(
    EditorCommentAdded(
      resource=@fileeditor.ModelUri::of(
        @interop.ChannelId::Local.test_resource("/work/project/src/main.mbt"),
      ),
      file=Relative("src/main.mbt"),
      range=@common.Range(5, 1, 6, 3),
      quote="fn parse_hover() {",
      comment="rename this",
      feedback_id="viewer-feedback-codex",
    ),
  )
  let (_, once) = update(dispatch, msg, model)
  let (_, twice) = update(dispatch, msg, model)
  assert_true(once.active().mentions.is_empty())
  assert_true(twice.active().mentions.is_empty())
  assert_eq(once.codex.draft_text(), twice.codex.draft_text())
  // The textarea stays untouched. Codex owns the annotation chip and sends
  // its file/range/comment/quote through the shared mention envelope.
  assert_eq(once.codex.draft_text(), "")
}

///|
test "Codex semantic selection becomes a composer chip" {
  let dispatch = test_dispatch()
  let reference = large_semantic_reference_for_test()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-semantic-selection",
      "cwd": "/work/project",
      "preview": "Semantic selection",
      "turns": [],
    },
  })
  let model = { ..test_model(), codex, screen: Codex, }
  let owner : @interop.ConversationKey = {
    channel: @interop.ChannelId::Local,
    session: "codex-thread-semantic-selection",
  }
  let (_, selected) = update(
    dispatch,
    FileEditor(
      @fileeditor.SemanticSelectionChanged(owner~, reference=Some(reference)),
    ),
    model,
  )
  let mentions = selected.codex_composer_input().draft.mentions
  assert_eq(mentions.length(), 1)
  assert_true(
    mentions[0].ref_ is @mention_context.SemanticSearch(current) &&
    current == reference,
  )

  let (_, cleared) = update(
    dispatch,
    FileEditor(@fileeditor.SemanticSelectionChanged(owner~, reference=None)),
    selected,
  )
  assert_true(cleared.codex_composer_input().draft.mentions.is_empty())
}

///|
test "Codex ApplyAllFeedback steers the running task through its composer" {
  let dispatch = test_dispatch()
  let codex = @codex.State::from_thread_snapshot({
    "thread": {
      "id": "codex-thread-feedback",
      "cwd": "/work/project",
      "preview": "Review",
      "turns": [
        { "id": "codex-turn-feedback", "status": "inProgress", "items": [] },
      ],
    },
  })
  let model = { ..test_model(), codex, screen: Codex, }
  let (_, batched) = update(
    dispatch,
    FileEditor(
      EditorCommentAdded(
        resource=@fileeditor.ModelUri::of(
          @interop.ChannelId::Local.test_resource("/work/project/README.md"),
        ),
        file=Relative("README.md"),
        range=@common.Range(3, 1, 6, 46),
        quote="DeepSeek, Kimi, and Z.AI GLM models",
        comment="make this clearer",
        feedback_id="viewer-feedback-codex-immediate",
      ),
    ),
    model,
  )
  let before = batched.codex_composer_input()
  assert_eq(before.draft.mentions.length(), 1)
  let (_, applied) = update(
    dispatch,
    FileEditor(@fileeditor.ApplyAllFeedback),
    batched,
  )
  assert_eq(
    before.draft.mentions,
    batched.codex_composer_input().draft.mentions,
  )
  let queued = applied.codex.transcript_items()
  assert_eq(queued.length(), 1)
  guard queued[0].kind is @transcript.User(content=prompt) else {
    fail("expected the queued comment as a user prompt")
  }
  assert_eq(
    prompt.text(),
    (
      #|<user_mentions>
      #|<annotation file="README.md" lines="3-6">
      #|<quote>
      #|DeepSeek, Kimi, and Z.AI GLM models
      #|</quote>
      #|<user_comment>
      #|make this clearer
      #|</user_comment>
      #|</annotation>
      #|</user_mentions>
    ),
  )
}
