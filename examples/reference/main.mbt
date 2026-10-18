///|
async fn main {
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/releases/earthquakes.csv", 28008L, "\"fixture-v1\"", "dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042",
  )
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-demo-")
  defer @fs.rmdir(dir, recursive=true)
  let publisher = dir + "/publisher.csv"
  let path = dir + "/unmanaged.csv"
  let metadata = dir + "/release-blocks.mfl"
  @fs.write_file(publisher, data)
  let pin = @host.write_block_reference(
    spec,
    publisher,
    metadata,
    chunk_size=4096,
  )
  let reference = @host.load_block_reference(spec, metadata, pin)
  @fs.write_file(path, data)
  let file = @fs.open(path, mode=ReadWrite)
  file.write_at(b"\x00", position=8195L)
  file.sync()
  file.close()
  let damaged = @fs.read_file(path).binary()
  let before = @fs.read_file(metadata).binary()
  let audit = @host.audit_with_reference(reference, path)
  assert_true(!audit.complete)
  assert_eq(audit.confirmed_bytes, 23912L)
  assert_eq(audit.missing_ranges, [{ start: 8192L, end: 12288L, }])
  assert_eq(audit.invalidated, audit.missing_ranges)
  assert_eq(
    @host.audit_with_reference(reference, path).to_json(),
    audit.to_json(),
  )
  assert_eq(@fs.read_file(path).binary(), damaged)
  assert_eq(@fs.read_file(metadata).binary(), before)
  for suffix in [".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
    assert_true(!@fs.exists(path + suffix) && !@fs.exists(publisher + suffix))
  }
  try
    @host.load_block_reference(spec, metadata, @ledger.digest(b"wrong"))
  catch {
    @ledger.InvalidCheckpoint(_) => ()
    _ => fail("wrong reference pin diagnostic")
  } noraise {
    _ => fail("accepted untrusted reference bytes")
  }
  assert_eq(@fs.read_file(metadata).binary(), before)
  println(
    "pinned reference audit verified: whole-source-gated publication, same-size damage without local checkpoint, retained=23912, one bad block, deterministic read-only report and no sidecar creation",
  )
}
