///|
pub suberror HostError {
  InvalidInput(String)
  InvalidResponse(String)
  CheckpointTooLarge
  OutputLocked
  RetryExhausted(@ledger.ByteRange, Int32, String)
} derive(Debug)

///|
pub extend HostError with Debug::{to_repr}

///|
pub struct DownloadReport {
  complete : Bool
  confirmed_bytes : Int64
  downloaded_blocks : Int32
  recovery : @ledger.RecoveryReport
} derive(Debug)

///|
pub extend DownloadReport with Debug::{to_repr}

///|
async fn save(session : @ledger.Session, checkpoint : String) -> Unit {
  replace_checkpoint(session, checkpoint, checkpoint + ".next")
}

///|
async fn receive(
  session : @ledger.Session,
  lease : @ledger.Lease,
  file : @fs.File,
  mutex : @async.Mutex,
  checkpoint : String,
  fetch_range : async (@ledger.ByteRange) -> ReceivedBlock,
  progress : ProgressTracker,
) -> Unit {
  let block = fetch_range(lease.range)
  let bytes = block.bytes
  let prepared = session.prepare_chunk(
    lease,
    bytes,
    status=block.status,
    etag=block.etag,
    range=block.range,
    total=block.total,
    content_encoding=block.content_encoding,
  )
  file.write_at(bytes, position=lease.range.start)
  file.sync()
  let readback = file.read_exactly_at(
    bytes.length(),
    position=lease.range.start,
  )
  mutex.acquire()
  defer mutex.release()
  session.commit_written(prepared, readback)
  save(session, checkpoint)
  progress.downloaded += 1
  progress.notify(session, BlockCommitted(lease.range))
}

///|
/// Native storage integration for an independently supplied range source.
/// The callback returns actual representation metadata, never invented status or
/// validators. Ledger validation runs before every content write. Output and its
/// .mfl checkpoint and .mfl.lock
/// form a single session. Retain all three when restarting. File locks coordinate
/// cooperating processes only; use a trusted directory with no external writers.
/// An optional block budget performs a controlled pause, returning complete=false.
/// Await on_progress serially after saved recovery/blocks and at the final phase.
/// Callback errors propagate without retrying notification or reverting saved data.
/// pause_signal stops new batches; the current batch drains and saves normally.
/// The callback may run concurrently, must bound response consumption and reject
/// unsupported transport metadata. No retries are performed by this storage layer.
pub async fn receive_from(
  spec : @ledger.ObjectSpec,
  output : String,
  fetch_range~ : async (@ledger.ByteRange) -> ReceivedBlock,
  chunk_size~ : Int32 = 65536,
  parallel~ : Int32 = 4,
  stop_after_blocks? : Int32,
  on_progress? : async (DownloadProgress) -> Unit,
  pause_signal? : @ledger.PauseSignal,
) -> DownloadReport {
  if output.is_empty() ||
    parallel < 1 ||
    parallel > 16 ||
    (stop_after_blocks is Some(limit) && limit < 0) {
    raise InvalidInput(
      "output required; parallel must be 1..16; block budget must be nonnegative",
    )
  }
  if chunk_size < 1 || chunk_size > 4194304 {
    raise InvalidInput("chunk size must be 1..4194304 bytes")
  }
  let checkpoint = output + ".mfl"
  if @fs.exists(checkpoint + ".next") || @fs.exists(checkpoint + ".recovering") {
    raise InvalidInput(
      "checkpoint temporary exists; retain it and use recover_checkpoint/--recover-checkpoint for a saved .next candidate; inspect .recovering separately",
    )
  }
  let lock = @fs.open(
    output + ".mfl.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  let session = if @fs.exists(checkpoint) {
    if @fs.file_size(checkpoint) > 16000000L {
      raise CheckpointTooLarge
    }
    @ledger.restore(@fs.read_file(checkpoint).text(), spec)
  } else {
    if @fs.exists(output) {
      raise InvalidInput(
        "output exists without checkpoint; choose a new path or restart explicitly",
      )
    }
    let fresh = @ledger.Session::new(spec, chunk_size~)
    save(fresh, checkpoint)
    fresh
  }
  let file = @fs.open(output, mode=ReadWrite, create_mode=OpenOrCreate)
  defer file.close()
  let size = file.size()
  if size > spec.length {
    raise InvalidInput("output contains extra data; refusing to truncate")
  }
  let invalidated = []
  for range in session.recovery_ranges() {
    let readback = if range.end > size {
      None
    } else {
      Some(file.read_exactly_at(range.length().to_int(), position=range.start))
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
  let progress : ProgressTracker = { callback: on_progress, downloaded: 0, }
  progress.notify(session, Recovered)
  let mutex = @async.Mutex::Mutex()
  let mut downloaded = 0
  let budget = stop_after_blocks.unwrap_or(100000)
  while downloaded < budget &&
        !(pause_signal is Some(signal) && signal.is_requested()) {
    let jobs : Array[async () -> Unit] = []
    for _ in 0..<parallel.min(budget - downloaded) {
      if session.reserve_missing() is Some(lease) {
        jobs.push(() => {
          receive(
            session, lease, file, mutex, checkpoint, fetch_range, progress,
          )
        })
      }
    }
    if jobs.is_empty() {
      break
    }
    ignore(@async.all(jobs))
    downloaded += jobs.length()
  }
  let complete = session.confirmed_bytes() == spec.length
  if complete {
    let verifier = session.verifier()
    while verifier.next_range() is Some(range) {
      verifier.push(
        file.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    verifier.finish()
    if file.size() != spec.length {
      raise InvalidResponse("output length changed during verification")
    }
  }
  progress.notify(session, if complete { Complete } else { Paused })
  {
    complete,
    confirmed_bytes: session.confirmed_bytes(),
    downloaded_blocks: downloaded,
    recovery,
  }
}
