///|
async fn main {
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let dir = @fs.tmpdir(prefix="moonfetchledger-controlled-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/data.csv"
  let requested : Array[Int32] = []
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let url = "http://127.0.0.1:\{server.addr.port()}"
    let serving = group.spawn(() => {
      while true {
        let (conn, _) = server.accept()
        let request = conn.read_request()
        if request.path == "/stop" {
          conn.send_response(200, "OK", extra_headers={ "Connection": "close" })
          conn.end_response()
          conn.close()
          break
        }
        group.spawn_bg(() => {
          defer conn.close()
          let bounds = request.headers.get("Range").unwrap()[6:]
            .split("-")
            .collect()
          let start = @strconv.parse_int(bounds[0])
          let end = @strconv.parse_int(bounds[1]) + 1
          requested.push(start)
          assert_eq(request.headers.get("If-Range"), Some("\"fixture-v1\""))
          conn.send_response(206, "Partial Content", extra_headers={
            "ETag": "\"fixture-v1\"",
            "Content-Range": "bytes \{start}-\{end - 1}/28008",
            "Connection": "close",
          })
          conn.write(data[start:end].to_owned())
          conn.end_response()
        })
      }
    })
    let spec = @ledger.ObjectSpec::new(
      url + "/data",
      28008L,
      "\"fixture-v1\"",
      "dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042",
    )
    let signal = @ledger.PauseSignal::new()
    let paused = @host.download(
      spec,
      path,
      chunk_size=4096,
      parallel=3,
      pause_signal=signal,
      on_progress=event => {
        if event.phase is @host.BlockCommitted(_) {
          signal.request_pause()
        }
      },
    )
    assert_true(!paused.complete)
    assert_eq(paused.confirmed_bytes, 12288L)
    assert_eq(paused.downloaded_blocks, 3)
    assert_eq(requested.length(), 3)
    assert_eq(@host.audit(spec, path).missing_ranges, [
      { start: 12288L, end: 28008L, },
    ])
    let resumed = @host.download(
      spec,
      path,
      parallel=2,
      pause_signal=@ledger.PauseSignal::new(),
    )
    assert_true(resumed.complete)
    assert_eq(resumed.recovery.retained_bytes, 12288L)
    assert_eq(resumed.downloaded_blocks, 4)
    assert_eq(requested.length(), 7)
    assert_eq(@fs.read_file(path).binary(), data)
    let reopened = @host.download(spec, path, pause_signal=signal)
    assert_true(reopened.complete)
    assert_eq(reopened.downloaded_blocks, 0)
    assert_eq(requested.length(), 7)
    let (response, _) = @http.get(url + "/stop")
    assert_eq(response.code, 200)
    serving.wait()
    println(
      "controlled pause verified: drained 3 blocks, retained 12288 bytes, resumed 4 blocks, trusted SHA-256 and zero-fetch complete reopen",
    )
  })
}
