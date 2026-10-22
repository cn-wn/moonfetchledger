///|
async test "single-seed scan bounds refuse before staging and permit a larger-budget retry" {
  let dir = @fs.tmpdir(prefix="mfl-scan-budget-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcc", 3)
  let seed = dir + "/seed"
  let output = dir + "/staging"
  @fs.write_file(seed, b"abc")
  let before = @fs.readdir(dir)
  for (scan, hash) in [(-1L, 4L), (2L, 4L), (3L, -1L), (3L, 3L), (3L, 0L)] {
    try
      @host.reuse_from_seed(
        reference,
        seed,
        output,
        max_scan_bytes=scan,
        max_hash_bytes=hash,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong seed scan budget error")
    } noraise {
      _ => fail("exceeded seed scan budget")
    }
    assert_eq(@fs.readdir(dir), before)
    assert_eq(@fs.read_file(seed).binary(), b"abc")
  }
  let preview = @host.preview_seed(
    reference,
    seed,
    max_scan_bytes=3L,
    max_hash_bytes=4L,
  )
  assert_eq(preview.hashed_bytes, 4L)
  assert_eq(preview.download_bytes(), 0L)
  assert_true(
    @host.reuse_from_seed(
      reference,
      seed,
      output,
      max_scan_bytes=3L,
      max_hash_bytes=4L,
    ).complete,
  )
  assert_eq(@fs.read_file(output).binary(), b"abcc")
}

///|
async test "scan work budget is shared across seeds and cannot be silently ignored on resume" {
  let dir = @fs.tmpdir(prefix="mfl-pool-budget-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEF", 3)
  let a = dir + "/a"
  let b = dir + "/b"
  let output = dir + "/staging"
  @fs.write_file(a, b"abc")
  @fs.write_file(b, b"DEF")
  for (scan, hash) in [(5L, 6L), (6L, 5L)] {
    try
      @host.reuse_from_seeds(
        reference,
        [a, b],
        output,
        max_scan_bytes=scan,
        max_hash_bytes=hash,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong pool scan budget error")
    } noraise {
      _ => fail("pool reset a limit between seeds")
    }
    assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
  }
  let preview = @host.preview_seeds(
    reference,
    [a, b],
    max_scan_bytes=6L,
    max_hash_bytes=6L,
  )
  assert_eq(preview.hashed_bytes, 6L)
  let result = @host.update_from_seeds(
    reference,
    [a, b],
    output,
    max_scan_bytes=6L,
    max_hash_bytes=6L,
  )
  assert_true(result.receive.complete)
  try
    @host.update_from_seed(reference, output, resuming=true, max_hash_bytes=0L)
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong resume scan-control refusal")
  } noraise {
    _ => fail("ignored scan budget on resume")
  }
  assert_eq(
    @host.update_from_seed(reference, output, resuming=true).receive.downloaded_blocks,
    0,
  )
  assert_eq(@fs.read_file(a).binary(), b"abc")
  assert_eq(@fs.read_file(b).binary(), b"DEF")
}
