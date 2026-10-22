///|
// Caller retains its source handle and cooperative lock for the entire scan.
async fn scan_seed_file(
  reference : @ledger.DeltaReference,
  source : @fs.File,
  max_scan_bytes? : Int64,
  max_hash_bytes? : Int64,
) -> @ledger.SeedPlan {
  check_scan_limits(max_scan_bytes?, max_hash_bytes?)
  if source.kind() != Regular {
    raise InvalidInput("seed must be a regular stable file")
  }
  let size = source.size()
  if max_scan_bytes is Some(limit) && size > limit {
    raise InvalidInput(
      "seed scan byte limit exceeded; increase max_scan_bytes before retrying",
    )
  }
  let scanner = reference.scanner()
  let mut offset = 0L
  let mut remaining = max_hash_bytes.unwrap_or(9223372036854775807L)
  while offset < size {
    let length = (size - offset).min(65536L).to_int()
    let step = scanner.push_bounded(
      source.read_exactly_at(length, position=offset),
      max_hash_bytes=remaining,
    )
    if step.blocked {
      raise InvalidInput(
        "seed SHA-256 work budget exhausted; increase max_hash_bytes and retry; no staging created",
      )
    }
    remaining -= step.hashed_bytes
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
  max_scan_bytes? : Int64,
  max_hash_bytes? : Int64,
) -> @ledger.SeedPlan {
  check_scan_limits(max_scan_bytes?, max_hash_bytes?)
  if seed.is_empty() || @fs.kind(seed) != Regular {
    raise InvalidInput("preview requires a regular seed")
  }
  let lock = reference_lock(seed)
  defer close_reference_lock(lock)
  let file = @fs.open(seed, mode=ReadOnly)
  defer file.close()
  scan_seed_file(reference, file, max_scan_bytes?, max_hash_bytes?)
}

///|
fn check_scan_limits(
  max_scan_bytes? : Int64,
  max_hash_bytes? : Int64,
) -> Unit raise HostError {
  if (max_scan_bytes is Some(n) && n < 0L) ||
    (max_hash_bytes is Some(n) && n < 0L) {
    raise InvalidInput("scan byte and hash-work limits must be nonnegative")
  }
}
