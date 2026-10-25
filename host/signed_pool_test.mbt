///|
async test "signed pool rejects conflicting controls and protected source aliases before acceptance" {
  let dir = @fs.tmpdir(prefix="mfl-signed-pool-controls-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEF", 3)
  let signed = release_bytes(2L, pin=@ledger.digest(reference.to_bytes()))
  let trust = release_trust()
  let state = dir + "/state"
  let output = dir + "/new"
  let a = dir + "/a"
  @fs.write_file(a, b"abc")
  @host.initialize_release_state(state, trust)
  let before = @fs.read_file(state).binary()
  for paths in [[], [a, a], [a, dir + "/./state"], Array::make(33, a)] {
    try
      @host.update_signed_release(
        signed,
        trust,
        state,
        output,
        now=120L,
        seeds=paths,
        metadata_file=dir + "/delta",
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong signed pool preflight error")
    } noraise {
      _ => fail("accepted invalid pool")
    }
    assert_eq(@fs.read_file(state).binary(), before)
    assert_true(!@fs.exists(output + ".mfl.lock"))
  }
  try
    @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      seed=a,
      seeds=[a],
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong conflicting seed error")
  } noraise {
    _ => fail("accepted seed and seeds")
  }
  try
    @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      resuming=true,
      max_hash_bytes=0L,
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong resume scan-control error")
  } noraise {
    _ => fail("ignored resume scan control")
  }
  try
    @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      seeds=[a],
      max_scan_bytes=-1L,
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong negative signed scan bound")
  } noraise {
    _ => fail("accepted negative limit")
  }
  assert_eq(@fs.read_file(state).binary(), before)
}

///|
async test "signed multi-seed budget failure retains acceptance and retries to verified offline delivery" {
  let dir = @fs.tmpdir(prefix="mfl-signed-pool-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEF", 3)
  let signed = release_bytes(2L, pin=@ledger.digest(reference.to_bytes()))
  let trust = release_trust()
  let state = dir + "/state"
  let output = dir + "/new"
  let a = dir + "/a"
  let b = dir + "/b"
  @fs.write_file(a, b"abc")
  @fs.write_file(b, b"DEF")
  @host.initialize_release_state(state, trust)
  let initial = @fs.read_file(state).binary()
  for (scan, hash) in [(5L, 6L), (6L, 5L)] {
    try
      @host.update_signed_release(
        signed,
        trust,
        state,
        output,
        now=120L,
        seeds=[a, b],
        metadata_file=dir + "/delta",
        max_scan_bytes=scan,
        max_hash_bytes=hash,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong signed pool budget refusal")
    } noraise {
      _ => fail("ignored total pool limit")
    }
    assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
    assert_true(@fs.read_file(state).binary() != initial)
  }
  let report = @host.update_signed_release(
    signed,
    trust,
    state,
    output,
    now=121L,
    seeds=[a, b],
    metadata_file=dir + "/delta",
    max_scan_bytes=6L,
    max_hash_bytes=6L,
    export_to=dir + "/ready",
  )
  assert_true(report.update.receive.complete && report.update.exported)
  assert_eq(report.update.receive.downloaded_blocks, 0)
  assert_eq(report.update.seed.unwrap().reused_bytes, 6L)
  assert_eq(@fs.read_file(dir + "/ready").binary(), b"abcDEF")
  assert_eq(
    @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=122L,
      resuming=true,
      metadata_file=dir + "/delta",
    ).update.receive.downloaded_blocks,
    0,
  )
  assert_eq(@fs.read_file(a).binary(), b"abc")
  assert_eq(@fs.read_file(b).binary(), b"DEF")
}
