///|
async test "pause before requests, reused intent and complete empty artifact" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-pause-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/data"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/data",
    3L,
    "\"v1\"",
    @ledger.digest(b"abc"),
  )
  let signal = @ledger.PauseSignal::new()
  let phases : Array[@host.DownloadPhase] = []
  let report = @host.download(spec, path, pause_signal=signal, on_progress=event => {
    phases.push(event.phase)
    if event.phase is @host.Recovered {
      signal.request_pause()
    }
  })
  assert_true(!report.complete)
  assert_eq(report.downloaded_blocks, 0)
  assert_true(phases[0] is @host.Recovered)
  assert_true(phases[1] is @host.Paused)
  let checkpoint = @fs.read_file(path + ".mfl").text()
  assert_true(!@host.download(spec, path, pause_signal=signal).complete)
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  assert_true(
    @host.download(audit_spec(b""), dir + "/empty", pause_signal=signal).complete,
  )
}

///|
async test "pause drains reserved batch and fresh resume requests only remaining blocks" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-drain-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/data"
  let data = b"abcdefghij"
  let signal = @ledger.PauseSignal::new()
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let spec = @ledger.ObjectSpec::new(
      "http://127.0.0.1:\{server.addr.port()}/data",
      10L,
      "\"v1\"",
      @ledger.digest(data),
    )
    let requested : Array[Int32] = []
    let serving = group.spawn(() => {
      for _ in 0..<4 {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        let bounds = request.headers.get("Range").unwrap()[6:]
          .split("-")
          .collect()
        let start = @strconv.parse_int(bounds[0])
        let end = @strconv.parse_int(bounds[1]) + 1
        requested.push(start)
        conn.send_response(206, "Partial Content", extra_headers={
          "ETag": "\"v1\"",
          "Content-Range": "bytes \{start}-\{end - 1}/10",
          "Connection": "close",
        })
        conn.write(data[start:end].to_owned())
        conn.end_response()
      }
    })
    let report = @host.download(
      spec,
      path,
      chunk_size=3,
      parallel=2,
      pause_signal=signal,
      on_progress=event => {
        if event.phase is @host.BlockCommitted(_) {
          signal.request_pause()
        }
      },
    )
    assert_true(!report.complete)
    assert_eq(report.downloaded_blocks, 2)
    assert_eq(report.confirmed_bytes, 6L)
    assert_eq(requested.length(), 2)
    assert_true(requested.contains(0) && requested.contains(3))
    let audit = @host.audit(spec, path)
    assert_eq(audit.confirmed_bytes, 6L)
    assert_eq(audit.missing_ranges, [{ start: 6L, end: 10L, }])
    let complete = @host.download(
      spec,
      path,
      parallel=2,
      pause_signal=@ledger.PauseSignal::new(),
    )
    serving.wait()
    assert_true(complete.complete)
    assert_eq(complete.downloaded_blocks, 2)
    assert_eq(complete.recovery.retained_bytes, 6L)
    assert_eq(requested.length(), 4)
    assert_eq(@fs.read_file(path).binary(), data)
  })
}

///|
async test "pause never disguises a fatal response in the draining batch" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-pause-failure-")
  defer @fs.rmdir(dir, recursive=true)
  let signal = @ledger.PauseSignal::new()
  let path = dir + "/data"
  let data = b"abcdef"
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let spec = @ledger.ObjectSpec::new(
      "http://127.0.0.1:\{server.addr.port()}/data",
      6L,
      "\"v1\"",
      @ledger.digest(data),
    )
    let serving = group.spawn(() => {
      for _ in 0..<2 {
        let (conn, _) = server.accept()
        let request = conn.read_request()
        // The client deliberately closes on a changed validator.
        group.spawn_bg(allow_failure=true, () => {
          defer conn.close()
          let first = request.headers.get("Range") == Some("bytes=0-2")
          if !first {
            while !signal.is_requested() {
              @async.sleep(1)
            }
          }
          conn.send_response(206, "Partial Content", extra_headers={
            "ETag": if first {
              "\"v1\""
            } else {
              "\"changed\""
            },
            "Content-Range": if first {
              "bytes 0-2/6"
            } else {
              "bytes 3-5/6"
            },
            "Connection": "close",
          })
          conn.write(if first { b"abc" } else { b"def" })
          conn.end_response()
        })
      }
    })
    let phases : Array[@host.DownloadPhase] = []
    try
      @host.download(
        spec,
        path,
        chunk_size=3,
        parallel=2,
        pause_signal=signal,
        on_progress=event => {
          phases.push(event.phase)
          if event.phase is @host.BlockCommitted(_) {
            signal.request_pause()
          }
        },
      )
    catch {
      @host.InvalidResponse(_) => ()
      _ => fail("incorrect draining failure diagnostic")
    } noraise {
      _ => fail("converted a fatal response into successful pause")
    }
    serving.wait()
    assert_true(signal.is_requested())
    assert_eq(phases.length(), 2)
    assert_eq(@host.audit(spec, path).confirmed_bytes, 3L)
  })
}
