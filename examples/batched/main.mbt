///|
async fn main {
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/usgs.csv",
    data.length().to_int64(),
    "\"v1\"",
    @ledger.digest(data),
  )
  let dir = @fs.tmpdir(prefix="mfl-batched-example-")
  defer @fs.rmdir(dir, recursive=true)
  let results : Array[String] = []
  for limit in [1, 64] {
    let output = dir + "/" + limit.to_string()
    let mut groups = 0
    let mut last = -1L
    let received = @host.receive_from(
      spec,
      output,
      chunk_size=32,
      parallel=4,
      checkpoint_blocks=limit,
      fetch_range=r => {
        bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
        status: 206,
        etag: spec.etag,
        range: r,
        total: spec.length,
        content_encoding: "identity",
      },
      on_progress=e => {
        if e.phase is @host.BlockCommitted(_) && e.confirmed_bytes != last {
          groups += 1
          last = e.confirmed_bytes
          let saved = @ledger.restore(
            @fs.read_file(output + ".mfl").text(),
            spec,
          )
          assert_eq(saved.recovery_ranges().length(), e.downloaded_blocks)
        }
      },
    )
    assert_true(received.complete)
    assert_eq(groups, if limit == 1 { 876 } else { 14 })
    assert_eq(@fs.read_file(output).binary(), data)
    results.push(@fs.read_file(output + ".mfl").text())
    @host.export_verified(spec, output, output + ".ready")
    assert_eq(@fs.read_file(output + ".ready").binary(), data)
    println(
      "USGS: 876 blocks, checkpoint_blocks=\{limit}, saved coverage groups=\{groups}; exact verified export",
    )
  }
  assert_eq(results[0], results[1])
  println(
    "batched/default checkpoint bytes are identical; source callback is local, not a network benchmark",
  )
}
