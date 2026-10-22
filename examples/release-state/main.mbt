///|
async fn main {
  let dir = @fs.tmpdir(prefix="mfl-release-state-example-")
  defer @fs.rmdir(dir, recursive=true)
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let publisher = dir + "/publisher"
  let old = dir + "/installed"
  let metadata = dir + "/v2.delta"
  let state = dir + "/release-state"
  @fs.write_file(publisher, data)
  @fs.write_file(old, data)
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/v2.csv",
    data.length().to_int64(),
    "\"v2\"",
    @ledger.digest(data),
  )
  let pin = @host.write_delta_reference(
    spec,
    publisher,
    metadata,
    chunk_size=4096,
  )
  // Public demonstration seed only, never a deployment key.
  let seed = Bytes::makei(32, i => (31 - i).to_byte())
  let trust = @release.ReleaseTrust::new(
    @ed25519.derive_public_key(seed),
    "earthquakes",
    "stable",
  )
  @host.initialize_release_state(state, trust)
  let v2 = @release.Release::new(
    "earthquakes", "stable", 2L, 100L, 200L, "https://example.test/v2.delta", pin,
  ).sign(seed)
  let result = @host.with_release_state(state, trust, v2, 120L, action=approved => {
    let reference = @host.load_delta_reference(
      metadata,
      approved.release.metadata_sha256,
    )
    @host.update_from_seed(
      reference,
      dir + "/staging",
      seed=old,
      export_to=dir + "/ready",
    )
  })
  assert_true(result.receive.complete && result.exported)
  assert_eq(result.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(dir + "/ready").binary(), data)
  let v1 = @release.Release::new(
    "earthquakes", "stable", 1L, 100L, 200L, "https://example.test/v2.delta", pin,
  ).sign(seed)
  let saved = @fs.read_file(state).binary()
  try @host.with_release_state(state, trust, v1, 121L, action=_ => ()) catch {
    @host.InvalidInput(_) => ()
    _ => fail("unexpected rollback result")
  } noraise {
    _ => fail("accepted old version")
  }
  assert_eq(@fs.read_file(state).binary(), saved)
  assert_eq(@fs.read_file(old).binary(), data)
  println(
    "signed USGS delivery verified: exact 28008 bytes, no artifact network, preserved installed file; reopened state rejects an older validly signed release",
  )
}
