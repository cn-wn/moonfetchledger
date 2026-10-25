///|
// Independent application: only public dependency APIs, no library internals.
async fn main {
  let args = @env.args()
  if args.length() != 2 {
    fail("usage: resource-maintainer INPUT_FILE (8192..16000000 bytes)")
  }
  let input = args[1]
  let source = @fs.open(input, mode=ReadOnly)
  defer source.close()
  let size = source.size()
  if source.kind() != Regular || size < 8192L || size > 16000000L {
    fail("input must be a stable regular file of 8192..16000000 bytes")
  }
  let data = source.read_exactly_at(size.to_int(), position=0L)
  if source.size() != size {
    fail("input changed length")
  }
  let dir = @fs.tmpdir(prefix="mfl-consumer-")
  defer @fs.rmdir(dir, recursive=true)
  let split = data.length() / 2 / 4096 * 4096
  let a = dir + "/old-a"
  let b = dir + "/old-b"
  @fs.write_file(a, b"old-a\n" + data[:split].to_owned())
  @fs.write_file(b, b"old-b\n" + data[split:].to_owned())
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/resource.bin",
    size,
    "\"consumer-v2\"",
    @ledger.digest(data),
  )
  let metadata = dir + "/v2.delta"
  let pin = @host.write_delta_reference(spec, input, metadata, chunk_size=4096)
  let reference = @host.load_delta_reference(metadata, pin)
  let scan_limit = size + 12L
  let preview = @host.preview_seeds(
    reference,
    [a, b],
    max_scan_bytes=scan_limit,
    max_hash_bytes=200000000L,
  )
  assert_eq(preview.download_bytes(), 0L)
  // Public deterministic TEST seed; deployments must provision real keys.
  let key = Bytes::makei(32, i => i.to_byte())
  let trust = @release.ReleaseTrust::new(
    @ed25519.derive_public_key(key),
    "offline-resources",
    "stable",
  )
  let signed = @release.Release::new(
    "offline-resources", "stable", 2L, 100L, 200L, "https://example.test/v2.delta",
    pin,
  ).sign(key)
  let state = dir + "/state"
  let staging = dir + "/staging"
  @host.initialize_release_state(state, trust)
  let delivered = @host.update_signed_release(
    signed,
    trust,
    state,
    staging,
    now=120L,
    seeds=[a, b],
    metadata_file=metadata,
    max_scan_bytes=scan_limit,
    max_hash_bytes=200000000L,
    export_to=dir + "/ready",
  )
  assert_true(delivered.update.receive.complete && delivered.update.exported)
  assert_eq(delivered.update.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(dir + "/ready").binary(), data)
  let damaged = @fs.open(staging, mode=ReadWrite)
  damaged.write_at(Bytes::make(1, data[4096] ^ 1), position=4096L)
  damaged.close()
  let repaired = @host.repair_from_local(spec, staging, input)
  assert_true(repaired.complete)
  assert_eq(repaired.repaired_blocks, 1)
  assert_eq(@fs.read_file(staging).binary(), data)
  let reopened = @host.update_signed_release(
    signed,
    trust,
    state,
    staging,
    now=121L,
    resuming=true,
    metadata_file=metadata,
  )
  assert_eq(reopened.update.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(a).binary(), b"old-a\n" + data[:split].to_owned())
  assert_eq(@fs.read_file(b).binary(), b"old-b\n" + data[split:].to_owned())
  assert_eq(source.read_exactly_at(size.to_int(), position=0L), data)
  println(
    "independent consumer verified: signed multi-file delivery, no artifact network, selective local repair and offline reopen; input preserved",
  )
}
