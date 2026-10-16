///|
pub enum LocalRepairPhase {
  Recovered
  BlockCopied(@ledger.ByteRange)
  Paused
  Complete
} derive(Debug)

///|
pub extend LocalRepairPhase with Debug::{to_repr}

///|
/// Immutable saved-coverage snapshot for a single offline repair invocation.
/// Recovered follows whole-backup verification and saved target reconciliation.
/// BlockCopied follows sync, readback and checkpoint save. Complete additionally
/// requires whole-target verification. Counts describe copied blocks, not reads.
pub struct LocalRepairProgress {
  phase : LocalRepairPhase
  total_bytes : Int64
  confirmed_bytes : Int64
  repaired_blocks : Int32
} derive(Debug)

///|
pub extend LocalRepairProgress with Debug::{to_repr}

///|
/// MFLREPAIR1: [version,phase,total,confirmed,copiedBlocks,rangeOrNull].
/// Decimal strings preserve Int64 precision. Ranges are half-open.
pub fn LocalRepairProgress::to_json(self : LocalRepairProgress) -> Json {
  let (phase, range) = match self.phase {
    Recovered => ("recovered", Json::null())
    BlockCopied(range) =>
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
    Json::string("MFLREPAIR1"),
    Json::string(phase),
    Json::string(self.total_bytes.to_string()),
    Json::string(self.confirmed_bytes.to_string()),
    Json::string(self.repaired_blocks.to_string()),
    range,
  ])
}

///|
priv struct LocalRepairTracker {
  callback : (async (LocalRepairProgress) -> Unit)?
  mut copied : Int32
}

///|
async fn LocalRepairTracker::notify(
  self : LocalRepairTracker,
  session : @ledger.Session,
  phase : LocalRepairPhase,
) -> Unit {
  if self.callback is Some(callback) {
    callback({
      phase,
      total_bytes: session.spec.length,
      confirmed_bytes: session.confirmed_bytes(),
      repaired_blocks: self.copied,
    })
  }
}
