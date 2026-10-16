///|
struct SteeringDraft {
  run_id : String
  text : String
  attachments : @attachments.Draft
}

///|
fn Chat::remember_steer(
  self : Chat,
  id : String,
  run_id : String,
  text : String,
) -> Unit {
  self.steering_drafts[id] = {
    run_id,
    text,
    attachments: self.attachments.copy(),
  }
  self.attachments.clear()
  if self.draft.text() == text {
    self.draft.clear()
  }
}

///|
fn Chat::reject_steer(self : Chat, id : String, run_id : String?) -> Bool {
  guard self.steering_drafts.get(id) is Some(submitted) &&
    run_id == Some(submitted.run_id) else {
    return false
  }
  self.steering_drafts.remove(id)
  self.pending.remove(id)
  self.queued.remove(id)
  self.queued_drafts.remove(id)
  let newer = self.draft.text()
  if newer.is_empty() {
    self.draft.set_text(submitted.text)
  } else if !submitted.text.is_empty() && newer != submitted.text {
    self.draft.set_text(submitted.text + "\n\n" + newer)
  }
  self.attachments.prepend(submitted.attachments)
  true
}

///|
fn Chat::acknowledge_steer(self : Chat, id : String, run_id : String?) -> Unit {
  if self.steering_drafts.get(id) is Some(submitted) {
    guard run_id == Some(submitted.run_id) else { return }
    self.steering_drafts.remove(id)
  }
  self.pending.remove(id)
  self.queued.remove(id)
  self.queued_drafts.remove(id)
}

///|
fn Chat::forget_steers_for_run(self : Chat, run_id : String) -> Unit {
  for id in self.steering_drafts.keys().collect() {
    if self.steering_drafts.get(id) is Some(submitted) &&
      submitted.run_id == run_id {
      self.steering_drafts.remove(id)
      self.pending.remove(id)
    }
  }
}
