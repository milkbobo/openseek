///|
test "the model selector switches one conversation, not the app" {
  let dispatch = test_dispatch()
  let model = test_model().replace_conversation(
    empty_conversation(
      @interop.ChannelId::Local,
      "other-chat",
      @interop.ChannelId::Local.test_project(),
    ),
  )
  let (_, flash) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    model,
  )
  assert_true(flash.active().engine_model is DsFlash)
  // The handler is pure: applying the same message to the same model produces
  // the same selected/default/stored model state.
  let (_, flash_again) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    model,
  )
  @debug.assert_eq(
    flash.active().engine_model,
    flash_again.active().engine_model,
  )
  @debug.assert_eq(flash.default_model, flash_again.default_model)
  @debug.assert_eq(flash.conversation_models, flash_again.conversation_models)
  // The conversation next door keeps the tier it was already on.
  guard flash.find_conversation(@interop.ChannelId::Local, "other-chat")
    is Some(other) else {
    fail("the second conversation vanished")
  }
  assert_true(other.engine_model is DsPro)
  // The tier just picked is what conversations opened afterwards start from.
  assert_true(flash.default_model is DsFlash)
  assert_true(
    flash
    .activate(
      @interop.ChannelId::Local,
      "fresh-chat",
      @interop.ChannelId::Local.test_project(),
    )
    .active().engine_model
    is DsFlash,
  )
  let (_, pro) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-pro"),
    flash,
  )
  assert_true(pro.active().engine_model is DsPro)
}

///|
test "a start never overrides the tier picked for the next turn" {
  let dispatch = test_dispatch()
  // The selector stays live while a turn spawns, so the user can change it for the
  // next turn before this one's `Started` arrives. The start is older than
  // that choice and must not undo it — the same holds for a turn another
  // client began, which says nothing about what this user means to send.
  let (_, queued) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    test_model(),
  )
  assert_true(queued.active().engine_model is DsFlash)
  let (_, ran) = update_dev(
    dispatch,
    Started(
      run_id="r1",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    queued,
  )
  assert_true(ran.active().engine_model is DsFlash)
}

///|
test "reopening a conversation recovers its own tier, not the last pick" {
  let dispatch = test_dispatch()
  // Set the chat on screen to DsFlash, then open a different one and put it
  // back on DsPro. The second pick moves the default new chats inherit — it
  // must not follow the first conversation home.
  let (_, flash) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    test_model(),
  )
  let other = flash.activate(
    @interop.ChannelId::Local,
    "other-chat",
    @interop.ChannelId::Local.test_project(),
  )
  assert_true(other.active().engine_model is DsFlash)
  let (_, pro) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-pro"),
    other,
  )
  assert_true(pro.default_model is DsPro)
  // Reopening drops the conversation and mints it again (nothing was sent,
  // so `activate` does not retain it) — exactly the path that used to hand
  // back the unrelated default.
  let reopened = pro.activate(
    @interop.ChannelId::Local,
    "desktop-test",
    @interop.ChannelId::Local.test_project(),
  )
  assert_true(reopened.active().engine_model is DsFlash)
}

///|
test "a run pins an inherited tier the user never clicked for" {
  let dispatch = test_dispatch()
  // This chat never touched the chip — it just inherited DsPro and ran. That
  // still has to pin, or a later toggle elsewhere silently retiers it.
  let (_, ran) = update_dev(
    dispatch,
    Started(
      run_id="r1",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    test_model(),
  )
  assert_true(
    ran.remembered_model(@interop.ChannelId::Local, "desktop-test")
    is Some(DsPro),
  )
  // Another chat moves the page default to DsFlash...
  let elsewhere = ran.activate(
    @interop.ChannelId::Local,
    "other-chat",
    @interop.ChannelId::Local.test_project(),
  )
  let (_, moved) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    elsewhere,
  )
  assert_true(moved.default_model is DsFlash)
  // ...and the first one still comes back on the tier it ran with.
  let reopened = moved.activate(
    @interop.ChannelId::Local,
    "desktop-test",
    @interop.ChannelId::Local.test_project(),
  )
  assert_true(reopened.active().engine_model is DsPro)
}

///|
test "a Codex pick hands a fresh chat to Codex" {
  let dispatch = test_dispatch()
  // The fixture chat has sent nothing, so its chip still offers both agent
  // groups. Picking a Codex model switches the surface and the defaults; the
  // real draft arrives via the rotation command's `CodexDraftRotated`.
  let (_, switched) = update(
    dispatch,
    ModelPicked("codex:gpt-5.4-codex"),
    test_model(),
  )
  assert_true(switched.screen is Codex)
  assert_true(switched.default_agent is CodexAgent)
  // One composing row at a time: the empty husk was only ever the "New
  // chat" placeholder, so it deactivates and its sidebar row goes with it.
  assert_true(switched.active_conversation() is None)
  // A husk holding typed writing keeps its row instead — switching back
  // finds the text.
  let typed = test_model().replace_conversation({
    ..test_conversation(),
    composer_draft_present: true,
  })
  let (_, kept) = update(dispatch, ModelPicked("codex:gpt-5.4-codex"), typed)
  assert_true(kept.screen is Codex)
  assert_true(kept.active_conversation() is Some(_))
}

///|
test "a begun conversation never changes agents" {
  let dispatch = test_dispatch()
  let (_, ran) = update_dev(
    dispatch,
    Started(
      run_id="r1",
      session="desktop-test",
      model=DsPro,
      max_steps=1000,
      session_root=None,
      submission_id=None,
    ),
    test_model(),
  )
  let (_, unchanged) = update(dispatch, ModelPicked("codex:gpt-5.4-codex"), ran)
  assert_true(unchanged.screen is Chat)
  assert_true(unchanged.default_agent is OpenSeekAgent)
}

///|
test "an OpenSeek pick on a composing Codex draft hands the chat back" {
  let dispatch = test_dispatch()
  let (_, drafting) = update(
    dispatch,
    CodexDraftRotated(cwd="/work", id="desktop-draft-1"),
    test_model(),
  )
  assert_true(drafting.screen is Codex)
  assert_true(drafting.codex.composing_draft())
  let (_, back) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    drafting,
  )
  assert_false(back.codex.composing_draft())
  assert_true(back.default_agent is OpenSeekAgent)
  assert_true(back.default_model is DsFlash)
}

///|
test "the Codex group's placeholder row opens Settings" {
  let dispatch = test_dispatch()
  let (_, opened) = update(
    dispatch,
    ModelPicked("codex.unavailable"),
    test_model(),
  )
  // Sign-in and connection state live in the Settings page's Codex group.
  assert_true(opened.screen is Settings)
  // A placeholder pick is a doorway, not a model: nothing was selected.
  assert_true(opened.default_agent is OpenSeekAgent)
}

///|
test "remembered tiers survive a round trip through storage" {
  let dispatch = test_dispatch()
  let (_, chosen) = update(
    dispatch,
    ModelPicked("openseek:deepseek-v4-flash"),
    test_model(),
  )
  let restored = parse_conversation_models(
    encoded_conversation_models(chosen.conversation_models),
  )
  assert_eq(restored, chosen.conversation_models)
  assert_true(restored is [{ key: "local/desktop-test", model: DsFlash, }])
}

///|
test "a write merges into the stored rows instead of replacing them" {
  // A sibling console tab on the same origin wrote these while this page held
  // a copy loaded at its own startup. Pinning here must not drop the other
  // tab's row — that conversation would silently revert to the default.
  let stored = parse_conversation_models(
    encoded_conversation_models([
      { key: "remote.b/sibling-chat", model: DsFlash, },
      { key: "remote.a/desktop-test", model: DsPro, },
    ]),
  )
  let merged = remembered_with(stored, "remote.a/desktop-test", DsFlash)
  assert_true(
    merged
    is [
      { key: "remote.a/desktop-test", model: DsFlash, },
      { key: "remote.b/sibling-chat", model: DsFlash, },
    ],
  )
}

///|
/// Test-only: the stored spelling of a remembered list, as
/// `save_conversation_model` writes it.
fn encoded_conversation_models(
  entries : Array[StoredConversationModel],
) -> String {
  let rows : Array[Json] = entries.map(entry => {
    "key": Json(entry.key),
    "model": Json(entry.model.wire()),
  })
  Json(rows).stringify()
}

///|
test "the remembered list stays capped, newest first" {
  let mut model = test_model()
  // One past the cap, so the first conversation chosen for is the one that
  // falls off and reverts to the page default.
  for index in 0..<=ConversationModelsLimit {
    model = model.remember_model(
      @interop.ChannelId::Local,
      "session-\{index}",
      if index % 2 == 0 {
        DsFlash
      } else {
        DsPro
      },
    )
  }
  assert_eq(model.conversation_models.length(), ConversationModelsLimit)
  assert_true(
    model.remembered_model(@interop.ChannelId::Local, "session-0") is None,
  )
  assert_true(
    model.remembered_model(
      @interop.ChannelId::Local,
      "session-\{ConversationModelsLimit}",
    )
    is Some(DsFlash),
  )
  // Re-choosing an existing conversation moves it, never duplicates it.
  let again = model.remember_model(
    @interop.ChannelId::Local,
    "session-1",
    DsFlash,
  )
  assert_eq(again.conversation_models.length(), ConversationModelsLimit)
  assert_true(
    again.remembered_model(@interop.ChannelId::Local, "session-1")
    is Some(DsFlash),
  )
}

///|
test "a conversation first met through a live run adopts its tier" {
  let dispatch = test_dispatch()
  // No local choice exists to contradict the run, so its tier is the best
  // evidence available — and it lands on that conversation alone, moving
  // neither the chat on screen nor the default new chats start from.
  let (_, background) = update_dev(
    dispatch,
    Started(
      run_id="r2",
      session="background-chat",
      model=DsPro,
      max_steps=1000,
      session_root=Some(@interop.ChannelId::Local.test_store_root()),
      submission_id=None,
    ),
    // The chat on screen sits on the page default, so the run's other tier
    // contrasts with both of the things it must not move.
    test_model().replace_conversation({
      ..test_conversation(),
      engine_model: DsFlash,
    }),
  )
  guard background.find_conversation(
      @interop.ChannelId::Local,
      "background-chat",
    )
    is Some(conv) else {
    fail("the background run materialized no conversation")
  }
  assert_true(conv.engine_model is DsPro)
  assert_true(background.active().engine_model is DsFlash)
  assert_true(background.default_model is DsFlash)
}

///|
test "GLM and DeepSeek remember independent reasoning choices" {
  let dispatch = test_dispatch()
  let glm = test_model().replace_conversation({
    ..test_conversation(),
    engine_model: Glm53,
  })
  guard glm.openseek_reasoning_chip(glm.active()) is Some(control) else {
    fail("GLM reasoning control was hidden")
  }
  assert_eq(control.selected, "no")
  assert_eq(control.options[0].label, "Low")
  assert_eq(control.title, "Reasoning effort: Low")
  // Max is not DeepSeek's default, so the two sides stay distinguishable.
  let (_, glm_max) = update(dispatch, OpenSeekEffortPicked("max"), glm)
  assert_true(glm_max.glm_reasoning is ReasoningMax)
  assert_true(glm_max.openseek_reasoning is ReasoningHigh)
  let deepseek = glm_max.replace_conversation({
    ..glm_max.active(),
    engine_model: DsPro,
  })
  let (_, deepseek_off) = update(dispatch, OpenSeekEffortPicked("no"), deepseek)
  assert_true(deepseek_off.openseek_reasoning is ReasoningOff)
  assert_true(deepseek_off.glm_reasoning is ReasoningMax)
}

///|
test "file context inherits the conversation model and its reasoning family" {
  let model = {
    ..test_model(),
    default_model: DsPro,
    openseek_reasoning: ReasoningMax,
    glm_reasoning: ReasoningOff,
  }
  let conv = test_conversation()
  for engine_model in [EngineModel::DsFlash, Glm53] {
    let ctx = file_ctx(model.replace_conversation({ ..conv, engine_model, }))
    assert_eq(ctx.model, engine_model.wire())
    assert_eq(
      ctx.thinking,
      if engine_model is Glm53 {
        Some(@protocol.ThinkingOff)
      } else {
        Some(@protocol.ThinkingMax)
      },
    )
  }
}
