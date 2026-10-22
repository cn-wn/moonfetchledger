///|
// Caller retains its source handle and cooperative lock for the entire scan.
async fn scan_seed_file(
  reference : @ledger.DeltaReference,
  source : @fs.File,
) -> @ledger.SeedPlan {
  if source.kind() != Regular {
    raise InvalidInput("seed must be a regular stable file")
  }
  let size = source.size()
  let scanner = reference.scanner()
  let mut offset = 0L
  while offset < size {
    let length = (size - offset).min(65536L).to_int()
    scanner.push(source.read_exactly_at(length, position=offset))
    offset += length.to_int64()
  }
  if source.size() != size {
    raise InvalidInput(
      "seed length changed while scanning; retain it and retry",
    )
  }
  scanner.finish()
}

///|
/// Read-only local preview. No network, output, sidecars or release-state writes.
/// Cooperates with existing seed locks. A later update rescans and rechecks bytes.
pub async fn preview_seed(
  reference : @ledger.DeltaReference,
  seed : String,
) -> @ledger.SeedPlan {
  if seed.is_empty() || @fs.kind(seed) != Regular {
    raise InvalidInput("preview requires a regular seed")
  }
  let lock = reference_lock(seed)
  defer close_reference_lock(lock)
  let file = @fs.open(seed, mode=ReadOnly)
  defer file.close()
  scan_seed_file(reference, file)
}
