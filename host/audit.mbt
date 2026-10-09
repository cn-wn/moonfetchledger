///|
pub struct AuditReport {
  complete : Bool
  output_present : Bool
  stored_bytes : Int64
  confirmed_bytes : Int64
  missing_ranges : Array[@ledger.ByteRange]
  invalidated : Array[@ledger.ByteRange]
} derive(Debug)

///|
pub extend AuditReport with Debug::{to_repr}

///|
fn ranges_json(ranges : Array[@ledger.ByteRange]) -> Json {
  Json::array(
    ranges.map(range => {
      Json::array([
        Json::string(range.start.to_string()),
        Json::string(range.end.to_string()),
      ])
    }),
  )
}

///|
/// Deterministic MFLAUDIT1 report. All offsets and sizes are decimal strings.
/// [version, complete, outputPresent, storedBytes, confirmedBytes, missing, invalidated]
pub fn AuditReport::to_json(self : AuditReport) -> Json {
  Json::array([
    Json::string("MFLAUDIT1"),
    Json::boolean(self.complete),
    Json::boolean(self.output_present),
    Json::string(self.stored_bytes.to_string()),
    Json::string(self.confirmed_bytes.to_string()),
    ranges_json(self.missing_ranges),
    ranges_json(self.invalidated),
  ])
}

///|
/// Inspect an existing session without network requests or content writes.
/// The expected identity must come from an independent trusted source. All
/// sidecars must be kept; absence of the existing lock/checkpoint is an error.
/// Cooperative shared locking excludes downloaders, not external writers.
pub async fn audit(spec : @ledger.ObjectSpec, output : String) -> AuditReport {
  if output.is_empty() ||
    !@fs.exists(output + ".mfl.lock") ||
    !@fs.exists(output + ".mfl") {
    raise InvalidInput(
      "audit requires an existing checkpoint and lock sidecar; retain all session files",
    )
  }
  let lock = @fs.open(output + ".mfl.lock", mode=ReadOnly)
  defer lock.close()
  if !lock.try_lock(Shared) {
    raise OutputLocked
  }
  let checkpoint = output + ".mfl"
  if @fs.file_size(checkpoint) > 16000000L {
    raise CheckpointTooLarge
  }
  let session = @ledger.restore(@fs.read_file(checkpoint).text(), spec)
  let file = if @fs.exists(output) {
    Some(@fs.open(output, mode=ReadOnly))
  } else {
    None
  }
  defer (match file {
    Some(f) => f.close()
    None => ()
  })
  let size = match file {
    Some(f) => f.size()
    None => 0L
  }
  if size > spec.length {
    raise InvalidInput(
      "output contains extra data; audit refuses unsupported trailing bytes",
    )
  }
  let invalidated = []
  for range in session.recovery_ranges() {
    let bytes = match file {
      Some(f) if range.end <= size =>
        Some(f.read_exactly_at(range.length().to_int(), position=range.start))
      _ => None
    }
    if !session.reconcile_block(range, bytes) {
      invalidated.push(range)
    }
  }
  session.finish_recovery()
  let complete = file is Some(_) && session.confirmed_bytes() == spec.length
  if complete && file is Some(f) {
    let verifier = session.verifier()
    while verifier.next_range() is Some(range) {
      verifier.push(
        f.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    verifier.finish()
    if f.size() != size {
      raise InvalidInput("output length changed during audit")
    }
  }
  {
    complete,
    output_present: file is Some(_),
    stored_bytes: size,
    confirmed_bytes: session.confirmed_bytes(),
    missing_ranges: session.unconfirmed_ranges(),
    invalidated,
  }
}
