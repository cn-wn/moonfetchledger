///|
pub enum DownloadPhase {
  Recovered
  BlockCommitted(@ledger.ByteRange)
  Paused
  Complete
} derive(Debug)

///|
pub extend DownloadPhase with Debug::{to_repr}

///|
/// Immutable snapshot. Counts describe confirmed saved coverage, not socket
/// traffic. Complete is emitted only after whole-file verification succeeds.
pub struct DownloadProgress {
  phase : DownloadPhase
  total_bytes : Int64
  confirmed_bytes : Int64
  downloaded_blocks : Int
} derive(Debug)

///|
pub extend DownloadProgress with Debug::{to_repr}

///|
/// Deterministic MFLPROGRESS1: [version,phase,total,confirmed,blocks,rangeOrNull].
/// Counts and offsets are decimal strings; block range is half-open.
pub fn DownloadProgress::to_json(self : DownloadProgress) -> Json {
  let (phase, range) = match self.phase {
    Recovered => ("recovered", Json::null())
    BlockCommitted(range) =>
      (
        "block",
        Json::array([
          Json::string(range.start.to_string()),
          Json::string(range.end.to_string()),
        ]),
      )
    Paused => ("paused", Json::null())
    Complete => ("complete", Json::null())
  }
  Json::array([
    Json::string("MFLPROGRESS1"),
    Json::string(phase),
    Json::string(self.total_bytes.to_string()),
    Json::string(self.confirmed_bytes.to_string()),
    Json::string(self.downloaded_blocks.to_string()),
    range,
  ])
}

///|
priv struct ProgressTracker {
  callback : (async (DownloadProgress) -> Unit)?
  mut downloaded : Int
}

///|
async fn ProgressTracker::notify(
  self : ProgressTracker,
  session : @ledger.Session,
  phase : DownloadPhase,
) -> Unit {
  if self.callback is Some(callback) {
    callback({
      phase,
      total_bytes: session.spec.length,
      confirmed_bytes: session.confirmed_bytes(),
      downloaded_blocks: self.downloaded,
    })
  }
}
