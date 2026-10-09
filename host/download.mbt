///|
pub suberror HostError {
  InvalidInput(String)
  InvalidResponse(String)
  CheckpointTooLarge
  OutputLocked
  RetryExhausted(@ledger.ByteRange, Int, String)
} derive(Debug)

///|
pub extend HostError with Debug::{to_repr}

///|
pub struct DownloadReport {
  complete : Bool
  confirmed_bytes : Int64
  downloaded_blocks : Int
  recovery : @ledger.RecoveryReport
} derive(Debug)

///|
pub extend DownloadReport with Debug::{to_repr}

///|
async fn save(session : @ledger.Session, checkpoint : String) -> Unit {
  @fs.write_file(checkpoint + ".next", session.checkpoint(), sync=Full)
  @fs.rename(checkpoint + ".next", checkpoint, replace=true)
}

///|
async fn receive(
  session : @ledger.Session,
  lease : @ledger.Lease,
  file : @fs.File,
  mutex : @async.Mutex,
  checkpoint : String,
  attempts : Int,
  delay : Int,
  timeout : Int,
) -> Unit {
  let bytes = fetch(session.spec, lease, attempts, delay, timeout)
  let prepared = session.prepare_chunk(
    lease,
    bytes,
    status=206,
    etag=session.spec.etag,
    range=lease.range,
    total=session.spec.length,
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
}

///|
/// Native HTTP/filesystem integration. Output plus .mfl checkpoint and .mfl.lock
/// form a single session. Retain all three when restarting. File locks coordinate
/// cooperating processes only; use a trusted directory with no external writers.
/// An optional block budget performs a controlled pause, returning complete=false.
pub async fn download(
  spec : @ledger.ObjectSpec,
  output : String,
  chunk_size? : Int = 65536,
  parallel? : Int = 4,
  stop_after_blocks? : Int,
  max_attempts? : Int = 1,
  retry_delay_ms? : Int = 200,
  request_timeout_ms? : Int = 30000,
) -> DownloadReport {
  if max_attempts < 1 ||
    max_attempts > 8 ||
    retry_delay_ms < 0 ||
    retry_delay_ms > 30000 ||
    request_timeout_ms < 1 ||
    request_timeout_ms > 120000 {
    raise InvalidInput(
      "attempts must be 1..8; retry delay 0..30000 ms; request timeout 1..120000 ms",
    )
  }
  if output.is_empty() ||
    parallel < 1 ||
    parallel > 16 ||
    (stop_after_blocks is Some(limit) && limit < 0) {
    raise InvalidInput(
      "output required; parallel must be 1..16; block budget must be nonnegative",
    )
  }
  if !spec.resource.has_prefix("http://") &&
    !spec.resource.has_prefix("https://") {
    raise InvalidInput("HTTP or HTTPS resource required")
  }
  if chunk_size < 1 || chunk_size > 4194304 {
    raise InvalidInput("chunk size must be 1..4194304 bytes")
  }
  let checkpoint = output + ".mfl"
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
  let mutex = @async.Mutex::Mutex()
  let mut downloaded = 0
  let budget = stop_after_blocks.unwrap_or(100000)
  while downloaded < budget {
    let jobs : Array[async () -> Unit] = []
    for _ in 0..<parallel.min(budget - downloaded) {
      if session.reserve_missing() is Some(lease) {
        jobs.push(() => {
          receive(
            session, lease, file, mutex, checkpoint, max_attempts, retry_delay_ms,
            request_timeout_ms,
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
  {
    complete,
    confirmed_bytes: session.confirmed_bytes(),
    downloaded_blocks: downloaded,
    recovery,
  }
}
