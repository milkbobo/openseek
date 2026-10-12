///|
fn running_conversation() -> Conversation {
  { ..test_conversation(), run: Open(run_id="r7", stage=Opened), }
}

///|
/// Test-only: the durable rows the sidebar would show for `ids`, all in the
/// fixture project's store. Opening a conversation reads its store from its
/// row, so a test that opens one has to list it first.
fn Model::with_listed(self : Model, ids : Array[String]) -> Model raise {
  self.with_dev(dev => {
    ..dev,
    sessions: ids.map(id => {
      (
        {
          id,
          title: Some(""),
          workspace: @interop.ChannelId::Local.test_project(),
          workspace_name: "work",
          updated_at_ms: None,
        } : @transcript.SessionListItem)
    }),
  })
}

///|
fn archived_loaded(
  items : Array[@transcript.SessionListItem],
  request_generation~ : Int32 = 0,
) -> Msg {
  on_home(
    ArchivedLoaded(
      items,
      connection_generation=0,
      request_generation~,
      fresh_session="desktop-archive-replacement",
    ),
  )
}

///|
fn running_model() -> Model {
  test_model().replace_conversation(running_conversation())
}

///|
fn with_pending_steers(
  conv : Conversation,
  texts : Array[String],
  run_id~ : String = "r7",
) -> Conversation {
  let mut next = conv
  for index, text in texts {
    next = next.enqueue_steer(
      "test-steer-" + index.to_string(),
      Some(run_id),
      text,
      text,
      [],
      FollowupSteer,
    )
  }
  next
}

///|
fn with_pending_prompt(
  conv : Conversation,
  id : String,
  text : String,
) -> Conversation {
  {
    ..conv,
    pending_prompt: Some({
      images: [],
      submission_id: id,
      draft: text,
      mentions: [],
    }),
  }
}

///|
fn host_settings(
  provider~ : String,
  revision~ : Int32 = 0,
  has_deepseek_key~ : Bool = false,
  has_glm_key~ : Bool = false,
  has_custom_key~ : Bool = false,
  custom_api_url~ : String = "",
) -> @protocol.SettingsStatusPayload {
  {
    revision,
    provider,
    custom_api_url: Some(custom_api_url),
    has_deepseek_key,
    has_glm_key,
    has_custom_key,
    followup_behavior: "steer",
  }
}

///|
/// Test-only: a page whose parent conversation owns one sub-run lane and whose
/// store also holds that sub-run's child transcript.
fn subrun_page(active~ : String, child_sync? : TranscriptSync) -> Model {
  let lane : @subrun.Lane = {
    id: "sr-1",
    kind: "explore",
    label: "where is X",
    steps: 0,
    activity: "",
    run: Some("r7"),
  }
  let base = running_conversation()
  let parent = { ..base, turn: { ..base.turn, subruns: [lane], }, }
  let child = {
    ..empty_conversation(
      @interop.ChannelId::Local,
      "desktop-test-sr-1",
      @interop.ChannelId::Local.test_project(),
    )
    // A child already read once. The positive watermark is what proves a
    // durable record exists, which is `can_reload_transcript`'s gate.
    ,
    watermark: 4,
    sync: child_sync.unwrap_or(Synced),
  }
  {
    ..test_model().replace_conversation(parent).replace_conversation(child),
    active_session: active,
  }
}

///|
fn subrun_child_of(model : Model) -> Conversation raise {
  guard model.find_conversation(@interop.ChannelId::Local, "desktop-test-sr-1")
    is Some(child) else {
    fail("expected the sub-run's child conversation")
  }
  child
}

///|
/// Test-only: a click on a draft mention chip in the fixture conversation's
/// composer.
fn mention_opened(mention : Mention) -> Msg {
  ComposerAction(
    @composer.MentionOpened(
      identity={
        owner: { channel: Local, session: "desktop-test", },
        archive_generation: 0,
      },
      mention~,
    ),
  )
}
