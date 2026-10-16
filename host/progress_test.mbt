///|
suberror ObserverStopped

///|
async test "progress describes saved recovery, pause and verified empty completion" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-progress-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/data",
    7L,
    "\"v1\"",
    @ledger.digest(b"abcdefg"),
  )
  let events : Array[@host.DownloadProgress] = []
  let report = @host.download(spec, path, stop_after_blocks=0, on_progress=event => {
    let restored = @ledger.restore(@fs.read_file(path + ".mfl").text(), spec)
    assert_eq(restored.recovery_ranges().length(), 0)
    events.push(event)
  })
  assert_true(!report.complete)
  assert_eq(events.length(), 2)
  assert_eq(
    events[0].to_json().stringify(),
    "[\"MFLPROGRESS1\",\"recovered\",\"7\",\"0\",\"0\",null]",
  )
  assert_eq(
    events[1].to_json().stringify(),
    "[\"MFLPROGRESS1\",\"paused\",\"7\",\"0\",\"0\",null]",
  )
  let empty = audit_spec(b"")
  events.clear()
  ignore(
    @host.download(empty, dir + "/empty", on_progress=event => {
      events.push(event)
    }),
  )
  assert_eq(events.length(), 2)
  assert_true(events[0].phase is @host.Recovered)
  assert_true(events[1].phase is @host.Complete)
  assert_eq(events[1].confirmed_bytes, 0L)
  let large = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/large",
    419430400000L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  events.clear()
  ignore(
    @host.download(
      large,
      dir + "/large",
      chunk_size=4194304,
      stop_after_blocks=0,
      on_progress=event => events.push(event),
    ),
  )
  assert_eq(
    events[1].to_json().stringify(),
    "[\"MFLPROGRESS1\",\"paused\",\"419430400000\",\"0\",\"0\",null]",
  )
}

///|
async test "progress errors propagate, release locks and never imply bad-digest completion" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-observer-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let spec = audit_spec(b"abc")
  @fs.write_file(path, b"abc")
  @host.adopt(spec, path, chunk_size=3)
  let checkpoint = @fs.read_file(path + ".mfl").text()
  let mut notifications = 0
  try
    @host.download(spec, path, on_progress=_ => {
      notifications += 1
      raise ObserverStopped
    })
  catch {
    ObserverStopped => ()
    _ => fail("lost observer error")
  } noraise {
    _ => fail("ignored observer failure")
  }
  assert_eq(notifications, 1)
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  assert_true(@host.download(spec, path).complete)
  let wrong = audit_spec(b"xyz")
  @fs.write_file(path + ".mfl", audit_checkpoint(wrong, b"abc", [0]))
  let events : Array[@host.DownloadProgress] = []
  try
    @host.download(wrong, path, on_progress=event => events.push(event))
  catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("incorrect whole-digest diagnostic")
  } noraise {
    _ => fail("accepted bad whole digest")
  }
  assert_eq(events.length(), 1)
  assert_true(events[0].phase is @host.Recovered)
}

///|
async test "block notifications see saved coverage; observer failure resumes without refetch" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-progress-http-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abcdefg"
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let spec = @ledger.ObjectSpec::new(
      "http://127.0.0.1:\{server.addr.port()}/data",
      7L,
      "\"v1\"",
      @ledger.digest(data),
    )
    let requested : Array[Int32] = []
    let serving = group.spawn(() => {
      for _ in 0..<3 {
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
          "Content-Range": "bytes \{start}-\{end - 1}/7",
          "Connection": "close",
        })
        conn.write(data[start:end].to_owned())
        conn.end_response()
      }
    })
    let events : Array[@host.DownloadProgress] = []
    try
      @host.download(spec, path, chunk_size=3, parallel=1, on_progress=event => {
        events.push(event)
        if event.phase is @host.BlockCommitted(range) {
          assert_eq(range, { start: 0L, end: 3L, })
          let restored = @ledger.restore(
            @fs.read_file(path + ".mfl").text(),
            spec,
          )
          assert_eq(restored.recovery_ranges(), [range])
          assert_eq(@fs.read_file(path).binary(), b"abc")
          raise ObserverStopped
        }
      })
    catch {
      ObserverStopped => ()
      _ => fail("lost post-save callback error")
    } noraise {
      _ => fail("ignored post-save callback failure")
    }
    assert_eq(requested, [0])
    assert_eq(events.length(), 2)
    assert_eq(
      events[1].to_json().stringify(),
      "[\"MFLPROGRESS1\",\"block\",\"7\",\"3\",\"1\",[\"0\",\"3\"]]",
    )
    let first_snapshot = events[1]
    events.clear()
    let report = @host.download(spec, path, parallel=1, on_progress=event => {
      if event.phase is @host.BlockCommitted(_) {
        let restored = @ledger.restore(
          @fs.read_file(path + ".mfl").text(),
          spec,
        )
        assert_eq(
          restored.recovery_ranges().length(),
          event.downloaded_blocks + 1,
        )
      }
      events.push(event)
    })
    serving.wait()
    assert_true(report.complete)
    assert_eq(report.downloaded_blocks, 2)
    assert_eq(report.recovery.retained_bytes, 3L)
    assert_eq(requested, [0, 3, 6])
    assert_eq(events.length(), 4)
    assert_true(events[0].phase is @host.Recovered)
    assert_eq(events[0].confirmed_bytes, 3L)
    assert_eq(events[1].confirmed_bytes, 6L)
    assert_eq(events[2].confirmed_bytes, 7L)
    assert_true(events[3].phase is @host.Complete)
    assert_eq(@fs.read_file(path).binary(), data)
    assert_eq(first_snapshot.confirmed_bytes, 3L)
    assert_eq(first_snapshot.downloaded_blocks, 1)
  })
}
