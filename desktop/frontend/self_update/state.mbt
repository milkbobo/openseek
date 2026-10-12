// The self-update flow, driven from this side: the app asks `check_update`
// once at startup (and whenever the user asks in Settings) and starts
// `download_update` by itself as soon as a check reports an installable
// release. The staged download then waits in `Ready` until the user asks to
// restart — confirming first when a conversation would be interrupted — and
// only that click walks `apply_update` → window close. The update manifest
// lives on the SeekMoon origin; there is one release stream, so the requests
// carry no parameters. Self-update always targets the page's own desktop
// host, never a focused remote device.

///|
/// Byte progress for the package currently being downloaded. The total is
/// optional because HTTP permits responses without Content-Length.
pub struct Progress {
  downloaded_bytes : Int32
  total_bytes : Int32?
} derive(Eq)

///|
pub extend Progress with Eq::{equal, not_equal}

///|
fn Progress::percentage(self : Progress) -> Int32? {
  match self.total_bytes {
    Some(total) if total > 0 =>
      Some(
        @cmp.minimum(
          100,
          (self.downloaded_bytes.to_double() * 100.0 / total.to_double()).to_int(),
        ),
      )
    _ => None
  }
}

///|
fn Progress::status_text(
  self : Progress,
  version : String,
  locale~ : @i18n.Locale = English,
) -> String {
  match (self.percentage(), self.total_bytes) {
    (Some(percent), Some(total)) => {
      let downloaded_mb = self.downloaded_bytes / (1024 * 1024)
      let total_mb = @cmp.maximum(1, total / (1024 * 1024))
      @settings.text(
        locale,
        DownloadProgress(version, percent, downloaded_mb, total_mb),
      )
    }
    _ if self.downloaded_bytes > 0 =>
      @settings.text(
        locale,
        DownloadBytes(version, self.downloaded_bytes / (1024 * 1024)),
      )
    _ => @settings.text(locale, DownloadVersion(version))
  }
}

///|
fn Progress::sidebar_label(
  locale~ : @i18n.Locale = English,
  self : Progress,
) -> String {
  match self.percentage() {
    Some(percent) =>
      match locale {
        SimplifiedChinese => "正在下载 \{percent}%"
        TraditionalChinese => "正在下載 \{percent}%"
        Japanese => "ダウンロード中 \{percent}%"
        English => "Downloading \{percent}%"
        Spanish => "Descargando \{percent}%"
      }
    None =>
      match locale {
        SimplifiedChinese => "正在下载…"
        TraditionalChinese => "正在下載…"
        Japanese => "ダウンロード中…"
        English => "Downloading…"
        Spanish => "Descargando…"
      }
  }
}

///|
/// Where the self-update flow stands, from "never checked" through the
/// download to the restart. One enum, so "checking", "downloading" and
/// "confirming" cannot overlap. Who asked (the user from Settings or the app
/// at startup) travels with the request instead — `explicit` on
/// `CheckFinished` — since it is a property of the reply's routing, not of
/// the state.
pub enum State {
  Unknown
  Checking
  UpToDate
  // A newer release; `installable` gates whether a download can start — a
  // dev binary or a platform without a package only gets the announcement.
  // Installable releases download themselves straight from the check, so
  // this state is the resting point after a failed download, where the
  // accent button offers a retry.
  Available(version~ : String, installable~ : Bool)
  // A download in flight — started by the app itself right after a check,
  // or by a retry click on the restored offer.
  Downloading(version~ : String, progress~ : Progress)
  // Downloaded and staged; restarting is the user's call.
  Ready(version~ : String)
  // The modal asking to interrupt running conversations is up.
  ConfirmingRestart(version~ : String)
  // The bundle is swapped; the window is about to close.
  Restarting(version~ : String)
  // What the Settings row shows when a check could not answer.
  CheckFailed(message~ : String)
} derive(Eq)

///|
pub extend State with Eq::{equal, not_equal}

///|
pub fn State::empty() -> State {
  Unknown
}

///|
pub(all) enum Msg {
  // The Settings "Check for updates" button.
  CheckClicked
  // A `check_update` reply; a request that never reached the host arrives
  // as `Unreachable`, so there is one shape to route. `explicit` marks a
  // check the user asked for, whose outcome is always worth stating; the
  // app's own startup check stays quiet unless something is actionable.
  CheckFinished(reply~ : @protocol.CheckUpdateReply, explicit~ : Bool)
  // The accent Update button (sidebar footer and the Settings row).
  UpdateClicked
  // The interrupt-confirmation modal's two answers.
  RestartConfirmed
  RestartCancelled
  // `update.download_progress`: the host's coalesced byte count.
  DownloadProgress(downloaded_bytes~ : Int32, total_bytes~ : Int32?)
  // `update.downloaded`: the release is staged, under the version the host
  // actually downloaded.
  Downloaded(version~ : String)
  // A download or an apply failed, for this reason.
  Failed(message~ : String)
  // `apply_update` swapped the bundle: the window closes so the host can
  // relaunch into the new version.
  Applied
}

///|
/// What a transition asks of the application around it.
pub(all) enum Event {
  // Something went wrong that the user should see whichever screen is up.
  Problem(String)
} derive(Eq, Debug)

///|
pub extend Event with Eq::{equal, not_equal}

///|
pub extend Event with Debug::{to_repr}

///|
/// `busy` is whether restarting now would cut a conversation off mid-run.
pub fn update(
  state : State,
  msg : Msg,
  emit : @cmd.Emit[Msg],
  busy~ : Bool,
  locale~ : @i18n.Locale = English,
) -> (State, @cmd.Cmd, Array[Event]) {
  match msg {
    CheckClicked =>
      // A user-initiated check; never stacks on an in-flight one, never
      // interrupts a download already underway, and never clobbers a staged
      // download waiting for its restart.
      if state
        is (Checking
        | ConfirmingRestart(..)
        | Downloading(..)
        | Ready(..)
        | Restarting(..)) {
        (state, @cmd.none, [])
      } else {
        (Checking, check(emit, explicit=true), [])
      }
    CheckFinished(reply~, explicit~) => {
      // A stale reply must not clobber a flow the user has since started
      // (confirming, downloading); only the waiting states accept results.
      guard state is (Unknown | Checking | UpToDate | CheckFailed(..)) else {
        return (state, @cmd.none, [])
      }
      match reply {
        @protocol.Available(version~, installable=true, ..) =>
          // An installable release downloads itself — restarting into it
          // stays the user's call.
          (
            Downloading(version~, progress={
              downloaded_bytes: 0,
              total_bytes: None,
            }),
            download(emit),
            [],
          )
        @protocol.Available(version~, installable=false, unavailable_reason~) =>
          (
            Available(version~, installable=false),
            @cmd.none,
            if unavailable_reason is Some(reason) {
              [Problem(reason)]
            } else {
              []
            },
          )
        @protocol.UpToDate =>
          // Only worth stating when the user asked; a quiet startup check
          // leaves nothing behind.
          (if explicit { UpToDate } else { Unknown }, @cmd.none, [])
        @protocol.Unreachable(reason~) =>
          // Offline is routine for the app, an answer for the user.
          if explicit {
            (
              CheckFailed(message=text(locale, UpdateServer(reason))),
              @cmd.none,
              [],
            )
          } else {
            (Unknown, @cmd.none, [])
          }
        @protocol.Malformed(reason~) =>
          // A garbage manifest also happens under captive portals, so the
          // app asking stays quiet (the host logged it); the user asking
          // gets the truth.
          if explicit {
            (
              CheckFailed(message=text(locale, UpdateReply(reason))),
              @cmd.none,
              [],
            )
          } else {
            (Unknown, @cmd.none, [])
          }
        @protocol.Broken(version~, reason~) => {
          // A broken package entry can only be the publisher's fault:
          // loud both ways.
          let message = "SeekMoon \{version} is published but its package is unusable: \{reason}"
          (
            CheckFailed(message~),
            @cmd.none,
            if explicit {
              []
            } else {
              [Problem(message)]
            },
          )
        }
      }
    }
    UpdateClicked =>
      // The one accent button walks the whole flow: from an offer it retries
      // the download (harmless while conversations run), from a staged
      // download it restarts — asking first when that would cut a
      // conversation off. The button does not render in other states, but a
      // stale click must not restart a download or replay an apply.
      match state {
        Available(version~, installable=true) =>
          (
            Downloading(version~, progress={
              downloaded_bytes: 0,
              total_bytes: None,
            }),
            download(emit),
            [],
          )
        Ready(version~) =>
          if busy {
            (ConfirmingRestart(version~), @cmd.none, [])
          } else {
            (Restarting(version~), apply(emit), [])
          }
        _ => (state, @cmd.none, [])
      }
    RestartConfirmed =>
      if state is ConfirmingRestart(version~) {
        (Restarting(version~), apply(emit), [])
      } else {
        (state, @cmd.none, [])
      }
    RestartCancelled =>
      if state is ConfirmingRestart(version~) {
        // The download already happened; declining the restart just parks
        // the staged release until the user is ready.
        (Ready(version~), @cmd.none, [])
      } else {
        (state, @cmd.none, [])
      }
    DownloadProgress(downloaded_bytes~, total_bytes~) =>
      if state is Downloading(version~, ..) {
        (
          Downloading(version~, progress={ downloaded_bytes, total_bytes, }),
          @cmd.none,
          [],
        )
      } else {
        // A late event must not revive a completed, failed, or never-started
        // download after the UI has moved to another state.
        (state, @cmd.none, [])
      }
    Downloaded(version~) =>
      if state is Downloading(..) {
        // Staged, not applied: swapping the bundle under the running app
        // waits for the user's restart, so nothing is pulled out from
        // beneath the process (or the person) mid-flight. The version shown
        // from here on is the one the host actually staged — its deliberate
        // re-check may have picked up a release newer than the one this
        // flow started from.
        (Ready(version~), @cmd.none, [])
      } else {
        (state, @cmd.none, [])
      }
    Failed(message~) => {
      // A failed download can be retried. A failed swap means the preflight
      // no longer considers this location replaceable, so withdraw the
      // button until a fresh check says otherwise. Both failures say why.
      let next = match state {
        Downloading(version~, ..) => Available(version~, installable=true)
        Restarting(version~) => Available(version~, installable=false)
        other => other
      }
      (next, @cmd.none, [Problem(message)])
    }
    Applied => (state, close_window(), [])
  }
}

///|
/// The accent button's label, on any screen: it tracks the automatic
/// download so its progress stays visible, and asks for the restart once the
/// release is staged. None while there is nothing to offer.
pub fn State::button_label(self : State, locale : @i18n.Locale) -> String? {
  match self {
    Available(installable=true, ..) => Some(text(locale, UpdateLabel))
    Downloading(progress~, ..) => Some(progress.sidebar_label(locale~))
    Ready(..) | ConfirmingRestart(..) =>
      Some(text(locale, RestartToUpdateLabel))
    Restarting(..) => Some(text(locale, RestartingLabel))
    _ => None
  }
}

///|
/// Whether a click on the accent button would do anything.
pub fn State::button_enabled(self : State) -> Bool {
  self is (Available(..) | Ready(..))
}
