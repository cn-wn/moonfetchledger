///|
/// Stages may repeat; byte counters restart at each stage.
pub(all) enum UpdatePhase {
  LoadingRelease
  Authorizing
  LoadingMetadata
  Scanning
  Reusing
  Recovering
  Downloading
  Verifying
  Exporting
  CheckingExport
  Finished
} derive(Eq, Debug)

///|
pub extend UpdatePhase with Eq::{equal, not_equal}

///|
pub extend UpdatePhase with Debug::{to_repr}

///|
/// Phase-local work, saved target coverage and explicit pause/restart boundary.
/// Bytes are Int64; to_json encodes them as decimal strings.
pub struct UpdateProgress {
  phase : UpdatePhase
  processed_bytes : Int64
  total_bytes : Int64
  confirmed_bytes : Int64
  resumable : Bool
  paused : Bool
} derive(Debug)

///|
pub extend UpdateProgress with Debug::{to_repr}

///|
pub fn UpdateProgress::to_json(self : UpdateProgress) -> Json {
  let phase = match self.phase {
    LoadingRelease => "release"
    Authorizing => "authorizing"
    LoadingMetadata => "metadata"
    Scanning => "scanning"
    Reusing => "reusing"
    Recovering => "recovering"
    Downloading => "downloading"
    Verifying => "verifying"
    Exporting => "exporting"
    CheckingExport => "export-readback"
    Finished => "finished"
  }
  Json::array([
    Json::string("MFLUPDATEPROGRESS1"),
    Json::string(phase),
    Json::string(if self.paused { "paused" } else { "running" }),
    Json::string(self.processed_bytes.to_string()),
    Json::string(self.total_bytes.to_string()),
    Json::string(self.confirmed_bytes.to_string()),
    Json::boolean(self.resumable),
  ])
}

///|
/// One operation at a time. Callbacks run serially and may request a pause;
/// their errors propagate. Create a new control/signal for a resumed operation.
pub struct UpdateControl {
  priv callback : (async (UpdateProgress) -> Unit)?
  priv signal : @ledger.PauseSignal
  priv mut last : UpdateProgress?
}

///|
pub fn UpdateControl::new(
  on_progress? : async (UpdateProgress) -> Unit,
  pause_signal~ : @ledger.PauseSignal = @ledger.PauseSignal::new(),
) -> UpdateControl {
  { callback: on_progress, signal: pause_signal, last: None, }
}

///|
pub fn UpdateControl::request_pause(self : UpdateControl) -> Unit {
  self.signal.request_pause()
}

///|
pub fn UpdateControl::is_pause_requested(self : UpdateControl) -> Bool {
  self.signal.is_requested()
}

///|
async fn update_pause(
  control : UpdateControl?,
  phase : UpdatePhase,
  resumable : Bool,
) -> Unit {
  if control is Some(c) && c.is_pause_requested() {
    let previous = c.last
    let paused : UpdateProgress = {
      phase,
      processed_bytes: previous.map(p => p.processed_bytes).unwrap_or(0L),
      total_bytes: previous.map(p => p.total_bytes).unwrap_or(0L),
      confirmed_bytes: previous.map(p => p.confirmed_bytes).unwrap_or(0L),
      resumable,
      paused: true,
    }
    c.last = Some(paused)
    if c.callback is Some(callback) {
      callback(paused)
    }
    raise UpdatePaused(phase, resumable)
  }
}

///|
async fn update_tick(
  control : UpdateControl?,
  phase : UpdatePhase,
  processed : Int64,
  total : Int64,
  confirmed : Int64,
  resumable : Bool,
  check_pause~ : Bool = true,
) -> Unit {
  if control is Some(c) {
    let event : UpdateProgress = {
      phase,
      processed_bytes: processed,
      total_bytes: total,
      confirmed_bytes: confirmed,
      resumable,
      paused: false,
    }
    c.last = Some(event)
    if c.callback is Some(callback) {
      callback(event)
    }
    if check_pause {
      update_pause(control, phase, resumable)
    }
  }
}
