///|
pub struct LocalRepairReport {
  complete : Bool
  confirmed_bytes : Int64
  repaired_blocks : Int32
  recovery : @ledger.RecoveryReport
} derive(Debug)

///|
pub extend LocalRepairReport with Debug::{to_repr}

///|
/// Repair an existing session using a complete local backup, without networking.
/// Verify the backup before any target writes, then revalidate each copied block,
/// sync/read back and save coverage. Retain valid blocks and never trim extra data.
/// Failure can leave durable partial progress; restart with the same identity.
/// Backup verification always finishes before copying or pause handling. A block
/// budget or pause signal stops between saved blocks. Callbacks are serialized,
/// describe durable progress, and propagate errors without undoing saved work.
/// Complete is reported only after target whole-file verification.
pub async fn repair_from_local(
  spec : @ledger.ObjectSpec,
  output : String,
  backup : String,
  stop_after_blocks? : Int32,
  on_progress? : async (LocalRepairProgress) -> Unit,
  pause_signal? : @ledger.PauseSignal,
) -> LocalRepairReport {
  if stop_after_blocks is Some(limit) && limit < 0 {
    raise InvalidInput("local repair block budget must be nonnegative")
  }
  let checkpoint = output + ".mfl"
  if output.is_empty() ||
    backup.is_empty() ||
    !@fs.exists(checkpoint) ||
    !@fs.exists(output + ".mfl.lock") ||
    !@fs.exists(backup) ||
    @fs.kind(backup) != Regular {
    raise InvalidInput(
      "local repair requires an existing session and regular backup",
    )
  }
  let entry = canonical_entry(output)
  if [entry, entry + ".mfl", entry + ".mfl.lock", entry + ".mfl.next"].contains(
      canonical_entry(backup),
    ) {
    raise InvalidInput("backup aliases a target session path")
  }
  let lock = @fs.open(output + ".mfl.lock", mode=ReadWrite)
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  if @fs.exists(checkpoint + ".next") || @fs.exists(checkpoint + ".recovering") {
    raise InvalidInput(
      "checkpoint temporary file exists; inspect it before repair",
    )
  }
  let session = load_checkpoint(checkpoint, spec)
  if @fs.exists(output) &&
    (@fs.kind(output) != Regular || @fs.file_size(output) > spec.length) {
    raise InvalidInput("target must be regular and contain no extra data")
  }
  let source = @fs.open(backup, mode=ReadOnly)
  defer source.close()
  if source.size() != spec.length {
    raise InvalidInput(
      "backup length must match exactly; refusing to trim or pad",
    )
  }
  let indexer = @ledger.StorageIndexer::new(spec, chunk_size=session.chunk_size)
  while indexer.next_range() is Some(range) {
    indexer.push(
      source.read_exactly_at(range.length().to_int(), position=range.start),
    )
  }
  ignore(indexer.finish())
  if source.size() != spec.length {
    raise InvalidInput("backup length changed during verification")
  }
  let target = @fs.open(output, mode=ReadWrite, create_mode=OpenOrCreate)
  defer target.close()
  let size = target.size()
  let invalidated = []
  for range in session.recovery_ranges() {
    let readback = if range.end > size {
      None
    } else {
      Some(
        target.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    if !session.reconcile_block(range, readback) {
      invalidated.push(range)
    }
  }
  session.finish_recovery()
  let recovery : @ledger.RecoveryReport = {
    retained_bytes: session.confirmed_bytes(),
    invalidated,
  }
  save(session, checkpoint)
  let tracker : LocalRepairTracker = { callback: on_progress, copied: 0, }
  tracker.notify(session, Recovered)
  let budget = stop_after_blocks.unwrap_or(100000)
  while tracker.copied < budget &&
        !(pause_signal is Some(signal) && signal.is_requested()) {
    let lease = match session.reserve_missing() {
      Some(lease) => lease
      None => break
    }
    let bytes = source.read_exactly_at(
      lease.range.length().to_int(),
      position=lease.range.start,
    )
    let prepared = indexer.prepare_repair(session, lease, bytes)
    target.write_at(bytes, position=lease.range.start)
    target.sync()
    session.commit_written(
      prepared,
      target.read_exactly_at(bytes.length(), position=lease.range.start),
    )
    save(session, checkpoint)
    tracker.copied += 1
    tracker.notify(session, BlockCopied(lease.range))
  }
  let complete = session.confirmed_bytes() == spec.length
  if complete {
    let verifier = session.verifier()
    while verifier.next_range() is Some(range) {
      verifier.push(
        target.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    verifier.finish()
  }
  if target.size() > spec.length ||
    (complete && target.size() != spec.length) ||
    source.size() != spec.length {
    raise InvalidInput("target or backup length changed during repair")
  }
  tracker.notify(session, if complete { Complete } else { Paused })
  {
    complete,
    confirmed_bytes: session.confirmed_bytes(),
    repaired_blocks: tracker.copied,
    recovery,
  }
}
