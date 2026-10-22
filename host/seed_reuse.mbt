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
/// Single-file convenience entry point using the shared pool reconstruction
/// engine. Requires new staging and preserves ordinary receiver recovery.
pub async fn reuse_from_seed(
  reference : @ledger.DeltaReference,
  seed : String,
  output : String,
) -> SeedReuseReport {
  reuse_from_seeds(reference, [seed], output)
}
