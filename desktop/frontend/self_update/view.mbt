///|
/// The Settings check-for-updates row: the last check's outcome — status
/// text, a download's progress, the restart button once a release is
/// staged, or the accent Update button a failed download restored — on the
/// left, the Check button on the right.
pub fn check_controls(
  locale : @i18n.Locale,
  emit : @cmd.Emit[Msg],
  state : State,
) -> Array[@html.Html] {
  let controls : Array[@html.Html] = []
  match state {
    Unknown => ()
    Checking =>
      controls.push(
        @html.span(
          class="update-status",
          @settings.text(locale, CheckingUpdate),
        ),
      )
    UpToDate =>
      controls.push(
        @html.span(class="update-status", @settings.text(locale, UpToDate)),
      )
    Available(version~, installable~) =>
      if installable {
        controls.push(
          @html.button(
            class="button primary",
            on_click=emit(UpdateClicked),
            @settings.text(locale, UpdateTo(version)),
          ),
        )
      } else {
        controls.push(
          @html.span(
            class="update-status",
            @settings.text(locale, CannotInstallUpdate(version)),
          ),
        )
      }
    Ready(version~) =>
      // The release is staged; this button is the restart the flow waits for.
      controls.push(
        @html.button(
          class="button primary",
          on_click=emit(UpdateClicked),
          @settings.text(locale, RestartToInstall(version)),
        ),
      )
    ConfirmingRestart(version~) =>
      // The interrupt modal is up over this row; keep the button visible
      // behind it so the row does not blink while the user decides.
      controls.push(
        @html.button(
          class="button primary",
          @settings.text(locale, RestartToInstall(version)),
        ),
      )
    Downloading(version~, progress~) => {
      let (fill_class, fill_style) = match progress.percentage() {
        Some(percent) =>
          ("update-progress-fill", ["--progress-width: \{percent}%"])
        None => ("update-progress-fill indeterminate", [])
      }
      controls.push(
        @html.div(class="update-progress", [
          @html.span(
            class="update-status",
            progress.status_text(version, locale~),
          ),
          // The runtime supplies only the measured percentage. CSS owns the
          // width property and appearance; the adjacent text is the
          // accessible progress value.
          @html.div(class="update-progress-track", [
            @html.div(class=fill_class, style=fill_style, ""),
          ]),
        ]),
      )
    }
    Restarting(version~) =>
      controls.push(
        @html.span(
          class="update-status",
          @settings.text(locale, RestartingVersion(version)),
        ),
      )
    CheckFailed(message~) =>
      controls.push(@html.span(class="update-status update-error", message))
  }
  controls.push(
    @html.button(
      class="button secondary",
      disabled=state
        is (Checking | Downloading(..) | Ready(..) | Restarting(..)),
      on_click=emit(CheckClicked),
      @settings.text(locale, CheckUpdates),
    ),
  )
  controls
}

///|
/// The modal shown when restarting into a staged update would cut running
/// conversations off: restarting tears the engine processes down mid-run.
/// The backdrop and the Cancel button both keep the current version running,
/// with the downloaded release parked for later. None unless that question
/// is the one being asked.
pub fn restart_modal(
  locale : @i18n.Locale,
  emit : @cmd.Emit[Msg],
  state : State,
) -> @html.Html? {
  guard state is ConfirmingRestart(version~) else { return None }
  Some(
    @html.div(class="modal-backdrop", on_click=emit(RestartCancelled), [
      @html.div(class="modal", [
        @html.div(class="modal-title", text(locale, RestartQuestion(version))),
        @html.div(class="modal-body", text(locale, InterruptForUpdate)),
        @html.div(class="modal-actions", [
          @html.button(
            class="button secondary",
            on_click=emit(RestartCancelled),
            text(locale, KeepWorking),
          ),
          @html.button(
            class="button primary",
            on_click=emit(RestartConfirmed),
            text(locale, RestartNow),
          ),
        ]),
      ]),
    ]),
  )
}
