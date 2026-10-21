///|
async fn main {
  let original = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  // A reproducible v2 derived from the real fixture: prefix insertion, removal,
  // reordering and a second insertion. This is not claimed to be a USGS release.
  let v2 = b"MoonFetchLedger v2\n" +
    original[8192:16384].to_owned() +
    b"new-section\n" +
    original[:4096].to_owned() +
    original[16384:].to_owned()
  let dir = @fs.tmpdir(prefix="moonfetchledger-delta-demo-")
  defer @fs.rmdir(dir, recursive=true)
  let publisher = dir + "/release-v2"
  let seed = dir + "/installed-v1"
  let output = dir + "/staging-v2"
  let metadata = dir + "/v2.delta"
  @fs.write_file(publisher, v2)
  @fs.write_file(seed, original)
  let old = @fs.open(seed, mode=ReadWrite)
  old.write_at(b"\x00", position=12000L)
  old.close()
  let old_bytes = @fs.read_file(seed).binary()
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/releases/v2.csv",
    v2.length().to_int64(),
    "\"v2\"",
    @ledger.digest(v2),
  )
  let pin = @host.write_delta_reference(
    spec,
    publisher,
    metadata,
    chunk_size=4096,
  )
  // In a real deployment obtain pin through an independent trusted channel.
  let reference = @host.load_delta_reference(metadata, pin)
  let scanner = reference.scanner()
  scanner.push(old_bytes)
  let plan = scanner.finish()
  assert_true(plan.matches().any(m => m.source.start != m.target.start))
  let report = @host.reuse_from_seed(reference, seed, output)
  assert_true(report.reused_bytes > 0L && report.reused_bytes < spec.length)
  assert_eq(report.reused_bytes, plan.reused_bytes)
  assert_eq(@host.audit(spec, output).confirmed_bytes, report.reused_bytes)
  // Offline completion from a fully verified publisher copy. Network completion
  // can instead use the existing HTTP/WebDAV receiver and the same MFL1 session.
  let completed = @host.repair_from_local(spec, output, publisher)
  assert_true(completed.complete)
  assert_eq(@fs.read_file(output).binary(), v2)
  assert_eq(@fs.read_file(seed).binary(), old_bytes)
  @host.export_verified(spec, output, dir + "/ready-v2")
  assert_eq(@fs.read_file(dir + "/ready-v2").binary(), v2)
  println(
    "cross-version reuse verified: old=\{original.length()} target=\{v2.length()} reused=\{report.reused_bytes} missing=\{spec.length - report.reused_bytes} moved blocks, damaged seed, preserved v1 and verified offline v2 export",
  )
}
