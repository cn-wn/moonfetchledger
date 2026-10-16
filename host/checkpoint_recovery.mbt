///|
// Register cleanup only after CreateNew succeeds. Existing temporaries must never
// be truncated. The caller holds the session's exclusive cooperative lock.
async fn replace_checkpoint(
  session : @ledger.Session,
  checkpoint : String,
  temporary : String,
) -> Unit {
  let text = session.checkpoint()
  let file = @fs.open(temporary, mode=ReadWrite, create_mode=CreateNew)
  let mut installed = false
  defer {
    file.close()
    if !installed && @fs.exists(temporary) {
      @fs.remove(temporary)
    }
  }
  file.write(text)
  file.sync()
  file.close()
  @fs.rename(temporary, checkpoint, replace=true)
  installed = true
}

///|
async fn recovery_read(
  file : @fs.File?,
  size : Int64,
  range : @ledger.ByteRange,
) -> Bytes? {
  match file {
    Some(f) if range.end <= size =>
      Some(f.read_exactly_at(range.length().to_int(), position=range.start))
    _ => None
  }
}

///|
fn failed_records(
  left : Array[@ledger.ByteRange],
  right : Array[@ledger.ByteRange],
) -> Array[@ledger.ByteRange] {
  let result = []
  let mut i = 0
  let mut j = 0
  while i < left.length() || j < right.length() {
    if j == right.length() ||
      (i < left.length() && left[i].start < right[j].start) {
      result.push(left[i])
      i += 1
    } else if i == left.length() || right[j].start < left[i].start {
      result.push(right[j])
      j += 1
    } else {
      result.push(left[i])
      i += 1
      j += 1
    }
  }
  result
}

///|
/// Explicitly recover an interrupted .mfl.next save without network/content writes.
/// Validate both identities/layouts and actual disk records. Refuse to lose any
/// currently valid recorded block. Verify complete candidates against whole SHA.
/// Validation failures preserve both checkpoints and output. On success install
/// reconciled coverage via an owned .mfl.recovering file, then consume .mfl.next.
/// I/O failure after installation may leave the candidate for a safe repeat.
pub async fn recover_checkpoint(
  spec : @ledger.ObjectSpec,
  output : String,
) -> AuditReport {
  let checkpoint = output + ".mfl"
  let candidate = checkpoint + ".next"
  let temporary = checkpoint + ".recovering"
  if output.is_empty() ||
    !@fs.exists(output + ".mfl.lock") ||
    !@fs.exists(candidate) {
    raise InvalidInput(
      "checkpoint recovery requires an existing lock sidecar and .mfl.next candidate",
    )
  }
  if @fs.exists(temporary) {
    raise InvalidInput(
      "recovery temporary .mfl.recovering exists; preserve and inspect it before retrying",
    )
  }
  if @fs.kind(candidate) != Regular ||
    @fs.kind(output + ".mfl.lock") != Regular ||
    (@fs.exists(checkpoint) && @fs.kind(checkpoint) != Regular) {
    raise InvalidInput(
      "checkpoint recovery requires regular checkpoint and lock files",
    )
  }
  let lock = @fs.open(output + ".mfl.lock", mode=ReadWrite)
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  let pending = load_checkpoint(candidate, spec)
  let current = if @fs.exists(checkpoint) {
    Some(load_checkpoint(checkpoint, spec))
  } else {
    None
  }
  if current is Some(saved) && saved.chunk_size != pending.chunk_size {
    raise InvalidInput(
      "checkpoint layouts differ; retain both and choose the intended session explicitly",
    )
  }
  if @fs.exists(output) && @fs.kind(output) != Regular {
    raise InvalidInput(
      "checkpoint recovery requires a regular artifact when present",
    )
  }
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
      "output contains extra data; checkpoint recovery refuses to truncate",
    )
  }
  let invalidated = []
  for range in pending.recovery_ranges() {
    if !pending.reconcile_block(range, recovery_read(file, size, range)) {
      invalidated.push(range)
    }
  }
  pending.finish_recovery()
  let gaps = pending.unconfirmed_ranges()
  let previous_invalidated = []
  // Both lists are sorted. A linear merge avoids quadratic comparisons for a
  // highly fragmented 100000-block session.
  if current is Some(saved) {
    let mut index = 0
    for range in saved.recovery_ranges() {
      if saved.reconcile_block(range, recovery_read(file, size, range)) {
        while index < gaps.length() && gaps[index].end <= range.start {
          index += 1
        }
        if index < gaps.length() && gaps[index].start < range.end {
          raise InvalidInput(
            "candidate would lose valid recorded coverage; preserve both checkpoints",
          )
        }
      } else {
        previous_invalidated.push(range)
      }
    }
    saved.finish_recovery()
  }
  let complete = file is Some(_) && pending.confirmed_bytes() == spec.length
  if complete && file is Some(f) {
    let verifier = pending.verifier()
    while verifier.next_range() is Some(range) {
      verifier.push(
        f.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    verifier.finish()
  }
  if file is Some(f) && f.size() != size {
    raise InvalidInput("output length changed during checkpoint recovery")
  }
  replace_checkpoint(pending, checkpoint, temporary)
  @fs.remove(candidate)
  {
    complete,
    output_present: file is Some(_),
    stored_bytes: size,
    confirmed_bytes: pending.confirmed_bytes(),
    missing_ranges: gaps,
    invalidated: failed_records(invalidated, previous_invalidated),
  }
}
