///|
async fn[T] with_seed_files(
  seeds : Array[String],
  action : async (Array[@fs.File]) -> T,
) -> T {
  if seeds.is_empty() || seeds.length() > 32 {
    raise InvalidInput("seed pool requires 1..32 regular files")
  }
  let entries : Array[String] = []
  for seed in seeds {
    if seed.is_empty() || @fs.kind(seed) != Regular {
      raise InvalidInput(
        "every seed must be regular; none are silently skipped",
      )
    }
    let entry = canonical_entry(seed)
    if entries.contains(entry) {
      raise InvalidInput(
        "duplicate or aliased seed path; supply each file once",
      )
    }
    entries.push(entry)
  }
  let files : Array[@fs.File] = []
  let locks : Array[@fs.File?] = []
  defer (for file in files {
    file.close()
  })
  defer (for lock in locks {
    close_reference_lock(lock)
  })
  for seed in seeds {
    locks.push(reference_lock(seed))
    let file = @fs.open(seed, mode=ReadOnly)
    files.push(file)
    if file.kind() != Regular {
      raise InvalidInput("seed must remain regular")
    }
  }
  action(files)
}

///|
async fn scan_seed_pool(
  reference : @ledger.DeltaReference,
  files : Array[@fs.File],
) -> @ledger.SeedPoolPlan {
  let pool = @ledger.SeedPool::new(reference)
  let sizes : Array[Int64] = []
  for file in files {
    sizes.push(file.size())
    pool.add(scan_seed_file(reference, file))
  }
  for i, file in files {
    if file.size() != sizes[i] {
      raise InvalidInput("seed pool changed length; retry stable files")
    }
  }
  pool.finish()
}

///|
/// Read-only union preview. Input order sets deterministic source priority.
pub async fn preview_seeds(
  reference : @ledger.DeltaReference,
  seeds : Array[String],
) -> @ledger.SeedPoolPlan {
  with_seed_files(seeds, files => scan_seed_pool(reference, files))
}

///|
/// Reconstruct a NEW session from 1..32 files without modifying any seed.
/// Hold all cooperative seed locks/handles through copying; strong-recheck every
/// chosen block, sync/read back and checkpoint it. Existing inputs are never
/// silently skipped. Missing blocks use ordinary receive_from/download/WebDAV.
pub async fn reuse_from_seeds(
  reference : @ledger.DeltaReference,
  seeds : Array[String],
  output : String,
) -> SeedReuseReport {
  if output.is_empty() {
    raise InvalidInput("seed pool output is required")
  }
  let target_entries : Array[String] = []
  for suffix in ["", ".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
    if @fs.exists(output + suffix) {
      raise InvalidInput(
        "seed reuse requires new output and sidecars; resume existing progress",
      )
    }
    target_entries.push(canonical_entry(output + suffix))
  }
  for seed in seeds {
    for suffix in ["", ".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
      if target_entries.contains(canonical_entry(seed + suffix)) {
        raise InvalidInput("seed/session path aliases target/session paths")
      }
    }
  }
  with_seed_files(seeds, files => {
    let sizes : Array[Int64] = []
    for file in files {
      sizes.push(file.size())
    }
    let plan = scan_seed_pool(reference, files)
    let lock = @fs.open(
      output + ".mfl.lock",
      mode=ReadWrite,
      create_mode=CreateNew,
    )
    defer lock.close()
    if !lock.try_lock(Exclusive) {
      raise OutputLocked
    }
    for suffix in ["", ".mfl", ".mfl.next", ".mfl.recovering"] {
      if @fs.exists(output + suffix) {
        raise InvalidInput("target appeared while scanning; preserve it")
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
      let source = files[record.seed_index]
      let lease = session
        .reserve_range(record.target)
        .unwrap_or_else(() => {
          raise InvalidInput("seed pool selected an unavailable block")
        })
      let bytes = source.read_exactly_at(
        record.source.length().to_int(),
        position=record.source.start,
      )
      let prepared = reference.prepare_reuse(session, lease, bytes)
      if source.size() != sizes[record.seed_index] {
        raise InvalidInput(
          "selected seed changed length; retain partial staging",
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
      while verifier.next_range() is Some(r) {
        verifier.push(
          target.read_exactly_at(r.length().to_int(), position=r.start),
        )
      }
      verifier.finish()
    }
    for i, file in files {
      if file.size() != sizes[i] {
        raise InvalidInput("seed pool changed length during reconstruction")
      }
    }
    if target.size() > reference.spec.length ||
      (complete && target.size() != reference.spec.length) {
      raise InvalidInput("target length changed during reconstruction")
    }
    {
      complete,
      scanned_bytes: plan.scanned_bytes,
      reused_bytes: session.confirmed_bytes(),
      reused_blocks: matches.length(),
      missing_ranges: session.unconfirmed_ranges(),
    }
  })
}
