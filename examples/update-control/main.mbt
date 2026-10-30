///|
async fn main {
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let dir = @fs.tmpdir(prefix="mfl-update-control-example-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/seed"
  let output = dir + "/staging"
  let ready = dir + "/ready"
  @fs.write_file(source, data)
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
  let signal = @ledger.PauseSignal::new()
  let control = @host.UpdateControl::new(pause_signal=signal, on_progress=p => {
    println(p.to_json().stringify())
    if p.phase == @host.CheckingExport && p.processed_bytes > 0L {
      signal.request_pause()
    }
  })
  try
    @host.update_from_seed(
      reference,
      output,
      seed=source,
      export_to=ready,
      checkpoint_blocks=4,
      control~,
    )
  catch {
    @host.UpdatePaused(@host.CheckingExport, true) => ()
    _ => fail("unexpected cancellation result")
  } noraise {
    _ => fail("ignored export cancellation")
  }
  assert_true(!@fs.exists(ready) && !@fs.exists(ready + ".next"))
  let resumed = @host.update_from_seed(
    reference,
    output,
    resuming=true,
    export_to=ready,
    control=@host.UpdateControl::new(on_progress=p => {
      println(p.to_json().stringify())
    }),
  )
  assert_true(resumed.receive.complete && resumed.exported)
  assert_eq(resumed.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(ready).binary(), data)
  assert_eq(@fs.read_file(source).binary(), data)
  println(
    "USGS update: cancelled private export readback, retained staging, resumed with zero artifact GETs and exact verified delivery",
  )
}
