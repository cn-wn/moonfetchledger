///|
// Optional shared cooperation with an existing managed session. Unmanaged files
// remain a caller-owned stable-input contract; auditing never creates sidecars.
async fn reference_lock(output : String) -> @fs.File? {
  let path = output + ".mfl.lock"
  if !@fs.exists(path) {
    if @fs.exists(output + ".mfl") ||
      @fs.exists(output + ".mfl.next") ||
      @fs.exists(output + ".mfl.recovering") {
      raise InvalidInput(
        "session metadata exists without its lock; retain all sidecars",
      )
    }
    return None
  }
  if @fs.kind(path) != Regular {
    raise InvalidInput("reference operation requires a regular lock sidecar")
  }
  let lock = @fs.open(path, mode=ReadOnly)
  let mut retained = false
  defer (if !retained { lock.close() })
  if !lock.try_lock(Shared) {
    raise OutputLocked
  }
  retained = true
  Some(lock)
}

///|
fn close_reference_lock(lock : @fs.File?) -> Unit {
  match lock {
    Some(file) => file.close()
    None => ()
  }
}

///|
/// Hash a stable complete local source, publish full MFL1 block records to a new
/// path and return their exact UTF-8 byte pin. No source or source-sidecar writes.
/// Existing destinations/temporaries and source session path aliases are refused.
pub async fn write_block_reference(
  spec : @ledger.ObjectSpec,
  source : String,
  destination : String,
  chunk_size~ : Int32 = 65536,
) -> String {
  let indexer = @ledger.StorageIndexer::new(spec, chunk_size~)
  if source.is_empty() || destination.is_empty() || @fs.kind(source) != Regular {
    raise InvalidInput(
      "block reference publication requires a regular source and new destination",
    )
  }
  let entry = canonical_entry(source)
  if [
      entry,
      entry + ".mfl",
      entry + ".mfl.lock",
      entry + ".mfl.next",
      entry + ".mfl.recovering",
    ].contains(canonical_entry(destination)) {
    raise InvalidInput(
      "block reference destination aliases a source session path",
    )
  }
  if @fs.exists(destination) || @fs.exists(destination + ".next") {
    raise InvalidInput(
      "block reference destination or temporary exists; retain it",
    )
  }
  let lock = reference_lock(source)
  defer close_reference_lock(lock)
  let file = @fs.open(source, mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular || file.size() != spec.length {
    raise InvalidInput(
      "block reference requires exact regular source length; refusing to trim or pad",
    )
  }
  while indexer.next_range() is Some(range) {
    indexer.push(
      file.read_exactly_at(range.length().to_int(), position=range.start),
    )
  }
  let text = indexer.block_reference().to_checkpoint()
  if file.size() != spec.length {
    raise InvalidInput(
      "source length changed during block reference publication",
    )
  }
  let bytes = @utf8.encode(text)
  if bytes.length() > 16000000 {
    raise CheckpointTooLarge
  }
  publish_new(destination, file => file.write(bytes))
  @ledger.digest(bytes)
}

///|
/// Bounded same-handle read followed by pin-before-parse authentication. The pin
/// must be distributed independently, not merely stored beside untrusted metadata.
/// Loading a reference does not read, adopt or modify any artifact or checkpoint.
pub async fn load_block_reference(
  spec : @ledger.ObjectSpec,
  path : String,
  expected_sha256 : String,
) -> @ledger.BlockReference {
  if path.is_empty() || @fs.kind(path) != Regular {
    raise InvalidInput("block reference input must be a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular {
    raise InvalidInput("block reference input must remain regular")
  }
  let size = file.size()
  if size > 16000000L {
    raise CheckpointTooLarge
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  if file.read_at(FixedArray::make(1, b'\x00'), position=size) != 0 ||
    file.size() != size {
    raise InvalidInput(
      "block reference length changed while reading; retain input",
    )
  }
  @ledger.BlockReference::from_bytes(bytes, expected_sha256, spec)
}

///|
// Caller holds the appropriate cooperative lock. No filesystem writes here.
async fn inspect_reference(
  reference : @ledger.BlockReference,
  output : String,
) -> (@ledger.Session, AuditReport) {
  if output.is_empty() || (@fs.exists(output) && @fs.kind(output) != Regular) {
    raise InvalidInput(
      "reference audit requires a regular artifact when present",
    )
  }
  let session = reference.session()
  let file = if @fs.exists(output) {
    Some(@fs.open(output, mode=ReadOnly))
  } else {
    None
  }
  defer close_reference_lock(file)
  let size = match file {
    Some(f) => {
      if f.kind() != Regular {
        raise InvalidInput("artifact must remain regular")
      }
      f.size()
    }
    None => 0L
  }
  if size > reference.spec.length {
    raise InvalidInput(
      "artifact contains extra data; reference audit refuses to truncate",
    )
  }
  let invalidated = []
  for range in session.recovery_ranges() {
    if !session.reconcile_block(range, recovery_read(file, size, range)) {
      invalidated.push(range)
    }
  }
  session.finish_recovery()
  let complete = file is Some(_) &&
    session.confirmed_bytes() == reference.spec.length
  if complete && file is Some(f) {
    let verifier = session.verifier()
    while verifier.next_range() is Some(range) {
      verifier.push(
        f.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    verifier.finish()
  }
  if file is Some(f) && f.size() != size {
    raise InvalidInput("artifact length changed during reference audit")
  }
  (
    session,
    {
      complete,
      output_present: file is Some(_),
      stored_bytes: size,
      confirmed_bytes: session.confirmed_bytes(),
      missing_ranges: session.unconfirmed_ranges(),
      invalidated,
    },
  )
}

///|
/// Audit storage against independently authenticated complete block records.
/// No network or artifact/sidecar writes, including for an unmanaged or absent
/// artifact. Existing local checkpoint contents are not trusted or consumed.
pub async fn audit_with_reference(
  reference : @ledger.BlockReference,
  output : String,
) -> AuditReport {
  if output.is_empty() {
    raise InvalidInput("reference audit requires an artifact path")
  }
  let lock = reference_lock(output)
  defer close_reference_lock(lock)
  let (_, report) = inspect_reference(reference, output)
  report
}
