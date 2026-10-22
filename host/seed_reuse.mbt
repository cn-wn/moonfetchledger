///|
/// Publish authenticated cross-version matching metadata after whole-file
/// verification. The returned byte pin needs an independent trusted channel.
pub async fn write_delta_reference(
  spec : @ledger.ObjectSpec,
  source : String,
  destination : String,
  chunk_size~ : Int32 = 65536,
) -> String {
  let indexer = @ledger.DeltaIndexer::new(spec, chunk_size~)
  if source.is_empty() || destination.is_empty() || @fs.kind(source) != Regular {
    raise InvalidInput(
      "delta publication requires a regular source and new metadata path",
    )
  }
  let entry = canonical_entry(source)
  let source_paths = [
    entry,
    entry + ".mfl",
    entry + ".mfl.lock",
    entry + ".mfl.next",
    entry + ".mfl.recovering",
  ]
  if source_paths.contains(canonical_entry(destination)) ||
    source_paths.contains(canonical_entry(destination + ".next")) ||
    @fs.exists(destination) ||
    @fs.exists(destination + ".next") {
    raise InvalidInput(
      "delta metadata aliases source/session paths or already exists; retain inputs",
    )
  }
  let lock = reference_lock(source)
  defer close_reference_lock(lock)
  let file = @fs.open(source, mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular || file.size() != spec.length {
    raise InvalidInput("delta publisher source must have exact expected length")
  }
  while indexer.next_range() is Some(range) {
    indexer.push(
      file.read_exactly_at(range.length().to_int(), position=range.start),
    )
  }
  let bytes = indexer.finish().to_bytes()
  if bytes.length() > 16000000 || file.size() != spec.length {
    raise InvalidInput(
      "delta metadata exceeds 16000000 bytes or publisher source changed",
    )
  }
  publish_new(destination, f => f.write(bytes))
  @ledger.digest(bytes)
}

///|
pub async fn load_delta_reference(
  path : String,
  expected_sha256 : String,
) -> @ledger.DeltaReference {
  if path.is_empty() || @fs.kind(path) != Regular {
    raise InvalidInput("delta metadata must be a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  if file.kind() != Regular || size > 16000000L {
    raise InvalidInput(
      "delta metadata requires a regular file of at most 16000000 bytes",
    )
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  let probe = FixedArray::make(1, b'\x00')
  if file.read_at(probe, position=size) != 0 || file.size() != size {
    raise InvalidInput("delta metadata length changed while reading")
  }
  @ledger.DeltaReference::from_bytes(bytes, expected_sha256)
}

///|
pub struct SeedReuseReport {
  complete : Bool
  scanned_bytes : Int64
  reused_bytes : Int64
  reused_blocks : Int32
  missing_ranges : Array[@ledger.ByteRange]
} derive(Debug)

///|
pub extend SeedReuseReport with Debug::{to_repr}

///|
/// Scan ONE old file at arbitrary offsets; recheck matched bytes before copying
/// into a NEW output, then sync/read back and checkpoint each copied block.
/// Unmatched blocks remain missing for receive_from/download/WebDAV. The seed
/// requires no checkpoint or trusted old digest and is never modified. Created
/// partial output/checkpoint/lock are retained on errors for normal recovery.
/// Callers must exclude unrelated writers; cooperative seed locks are respected.
pub async fn reuse_from_seed(
  reference : @ledger.DeltaReference,
  seed : String,
  output : String,
) -> SeedReuseReport {
  if seed.is_empty() || output.is_empty() || @fs.kind(seed) != Regular {
    raise InvalidInput(
      "seed reuse requires a regular old file and new output path",
    )
  }
  let entry = canonical_entry(output)
  if [
      entry,
      entry + ".mfl",
      entry + ".mfl.lock",
      entry + ".mfl.next",
      entry + ".mfl.recovering",
    ].contains(canonical_entry(seed)) {
    raise InvalidInput("seed aliases target or its session paths")
  }
  for suffix in ["", ".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
    if @fs.exists(output + suffix) {
      raise InvalidInput(
        "seed reuse requires new output and sidecars; resume existing progress through receive_from/download",
      )
    }
  }
  let seed_lock = reference_lock(seed)
  defer close_reference_lock(seed_lock)
  let source = @fs.open(seed, mode=ReadOnly)
  defer source.close()
  if source.kind() != Regular {
    raise InvalidInput("seed must remain regular")
  }
  let size = source.size()
  let plan = scan_seed_file(reference, source)
  if source.size() != size {
    raise InvalidInput(
      "seed length changed while scanning; retry with stable seed",
    )
  }
  let lock = @fs.open(
    output + ".mfl.lock",
    mode=ReadWrite,
    create_mode=CreateNew,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  // Recheck under the lock before creating or publishing anything else.
  for suffix in ["", ".mfl", ".mfl.next", ".mfl.recovering"] {
    if @fs.exists(output + suffix) {
      raise InvalidInput("target appeared during seed scan; retain it")
    }
  }
  let session = @ledger.Session::new(
    reference.spec,
    chunk_size=reference.chunk_size,
  )
  let target = @fs.open(output, mode=ReadWrite, create_mode=CreateNew)
  defer target.close()
  publish_new(output + ".mfl", f => f.write(session.checkpoint()))
  let matches = plan.matches()
  for record in matches {
    let lease = match session.reserve_range(record.target) {
      Some(lease) => lease
      None =>
        raise InvalidInput("seed plan contains an unavailable target block")
    }
    let bytes = source.read_exactly_at(
      record.source.length().to_int(),
      position=record.source.start,
    )
    let prepared = reference.prepare_reuse(session, lease, bytes)
    if source.size() != size {
      raise InvalidInput(
        "seed length changed before copying; retain partial progress",
      )
    }
    target.write_at(bytes, position=record.target.start)
    target.sync()
    session.commit_written(
      prepared,
      target.read_exactly_at(bytes.length(), position=record.target.start),
    )
    save(session, output + ".mfl")
  }
  let complete = session.confirmed_bytes() == reference.spec.length
  if complete {
    let verifier = session.verifier()
    while verifier.next_range() is Some(range) {
      verifier.push(
        target.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    verifier.finish()
  }
  if source.size() != size ||
    target.size() > reference.spec.length ||
    (complete && target.size() != reference.spec.length) {
    raise InvalidInput("seed or target length changed during reconstruction")
  }
  {
    complete,
    scanned_bytes: plan.scanned_bytes,
    reused_bytes: session.confirmed_bytes(),
    reused_blocks: matches.length(),
    missing_ranges: session.unconfirmed_ranges(),
  }
}
