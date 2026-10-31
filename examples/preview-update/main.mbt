///|
async fn main {
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let dir = @fs.tmpdir(prefix="mfl-preview-update-example-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/publisher"
  let seed_a = dir + "/old-a"
  let seed_b = dir + "/old-b"
  let output = dir + "/staging"
  @fs.write_file(source, data)
  @fs.write_file(seed_a, data[:12288].to_owned())
  @fs.write_file(seed_b, data[12288:].to_owned())
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/usgs.csv",
    data.length().to_int64(),
    "\"v1\"",
    @ledger.digest(data),
  )
  let pin = @host.write_delta_reference(
    spec,
    source,
    dir + "/delta",
    chunk_size=4096,
  )
  let reference = @host.load_delta_reference(dir + "/delta", pin)
  let mut approved = false
  let mut decisions = 0
  let control = @host.UpdateControl::new(on_progress=p => {
    if approved {
      assert_true(p.phase != @host.Scanning)
    }
  })
  let result = @host.update_from_seeds(
    reference,
    [seed_a, seed_b],
    output,
    export_to=dir + "/ready",
    checkpoint_blocks=4,
    control~,
    on_preview=plan => {
      assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
      println(plan.to_json().stringify())
      decisions += 1
      approved = true
      // A real UI can ask the user here; a library can enforce a download budget.
      plan.download_bytes() == 0L
    },
  )
  assert_eq(decisions, 1)
  assert_true(result.receive.complete && result.exported)
  assert_eq(result.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(dir + "/ready").binary(), data)
  assert_eq(@fs.read_file(seed_a).binary(), data[:12288].to_owned())
  assert_eq(@fs.read_file(seed_b).binary(), data[12288:].to_owned())
  println(
    "USGS: one union scan, approval before staging, strong recheck on copy, zero artifact GETs and exact verified export",
  )
}
