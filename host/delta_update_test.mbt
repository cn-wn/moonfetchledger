///|
async test "update preflight preserves files and explicit resume delivers only verified content" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-update-preflight-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFabc!", 3)
  let seed = dir + "/old"
  let output = dir + "/new"
  @fs.write_file(seed, b"!DEFabc")
  @fs.write_file(dir + "/occupied", b"foreign")
  for
    (parallel, attempts, timeout, budget) in [
      (0, 1, 1, 0),
      (17, 1, 1, 0),
      (1, 0, 1, 0),
      (1, 9, 1, 0),
      (1, 1, 0, 0),
      (1, 1, 120001, 0),
      (1, 1, 1, -1),
    ] {
    try
      @host.update_from_seed(
        reference,
        output,
        seed~,
        parallel~,
        max_attempts=attempts,
        request_timeout_ms=timeout,
        stop_after_blocks=budget,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong update policy error")
    } noraise {
      _ => fail("accepted invalid update policy")
    }
    assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
  }
  try
    @host.update_from_seed(
      reference,
      output,
      seed~,
      export_to=dir + "/occupied",
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong delivery refusal")
  } noraise {
    _ => fail("overwrote destination")
  }
  assert_eq(@fs.read_file(dir + "/occupied").binary(), b"foreign")
  assert_true(!@fs.exists(output))
  try @host.update_from_seed(reference, output, seed~, resuming=true) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong resume policy")
  } noraise {
    _ => fail("ignored seed during resume")
  }
  let first = @host.update_from_seed(
    reference,
    output,
    seed~,
    export_to=dir + "/ready",
  )
  assert_true(first.receive.complete && first.exported)
  assert_eq(first.seed.unwrap().reused_bytes, 10L)
  assert_eq(first.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(dir + "/ready").binary(), b"abcDEFabc!")
  let checkpoint = @fs.read_file(output + ".mfl").binary()
  try @host.update_from_seed(reference, output, seed~) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong duplicate update refusal")
  } noraise {
    _ => fail("silently restarted")
  }
  assert_eq(@fs.read_file(output + ".mfl").binary(), checkpoint)
  let resumed = @host.update_from_seed(
    reference,
    output,
    resuming=true,
    export_to=dir + "/ready-again",
  )
  assert_true(
    resumed.seed is None && resumed.exported && resumed.receive.complete,
  )
  assert_eq(resumed.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(seed).binary(), b"!DEFabc")
}

///|
async test "remote delta input policy refuses malformed pins URLs and limits before network" {
  for
    url in [
      "file:///metadata", "http:///metadata", "http://user:secret@127.0.0.1/m", "http://127.0.0.1:0/m",
      "http://127.0.0.1:01/m", "http://[::1]/m", "http://127.0.0.1/m#fragment", "http://bad host/m",
    ] {
    try
      @host.fetch_delta_reference(
        url,
        @ledger.digest(b"x"),
        request_timeout_ms=1,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("URL was not refused before I/O")
    } noraise {
      _ => fail("accepted unsupported URL")
    }
  }
  for pin in ["", "A".repeat(64), "g".repeat(64), "0".repeat(63)] {
    try
      @host.fetch_delta_reference(
        "http://127.0.0.1:1/meta",
        pin,
        request_timeout_ms=1,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("pin was not refused before I/O")
    } noraise {
      _ => fail("accepted malformed pin")
    }
  }
  for timeout in [0, 120001] {
    try
      @host.fetch_delta_reference(
        "http://127.0.0.1:1/meta",
        @ledger.digest(b"x"),
        request_timeout_ms=timeout,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("timeout was not refused before I/O")
    } noraise {
      _ => fail("accepted invalid timeout")
    }
  }
}

///|
async test "remote metadata refuses redirects encoding ranges size overflow and changed bytes then retries" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-metadata-http-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcdefg", 3)
  let data = reference.to_bytes()
  let pin = @ledger.digest(data)
  let mut trap_calls = 0
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let base = "http://127.0.0.1:\{server.addr.port()}"
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
        group.spawn_bg(allow_failure=true, () => {
          defer conn.close()
          let headers : @http.Headers = { "Connection": "close" }
          if request.path == "/trap" {
            trap_calls += 1
          }
          if request.path == "/redirect" {
            headers["Location"] = base + "/trap"
            conn.send_response(302, "Moved", extra_headers=headers)
            conn.end_response()
            return
          }
          if request.path == "/encoded" {
            headers["Content-Encoding"] = "gzip"
          }
          if request.path == "/range" {
            headers["Content-Range"] = "bytes 0-0/1"
          }
          if request.path == "/length" {
            headers["Content-Length"] = "16000001"
          }
          conn.send_response(200, "OK", extra_headers=headers)
          if request.path == "/overflow" {
            conn.write(Bytes::make(16000001, b'x'))
          } else if request.path != "/length" {
            conn.write(
              if request.path == "/changed" {
                b"changed"
              } else {
                data
              },
            )
          }
          conn.end_response()
        })
      }
    })
    for path in ["/redirect", "/encoded", "/range", "/length", "/overflow"] {
      try @host.fetch_delta_reference(base + path, pin) catch {
        @host.InvalidResponse(_) => ()
        _ => fail("wrong metadata response error")
      } noraise {
        _ => fail("accepted invalid HTTP metadata")
      }
    }
    assert_eq(trap_calls, 0)
    try @host.fetch_delta_reference(base + "/changed", pin) catch {
      @ledger.InvalidManifest(_) => ()
      _ => fail("wrong changed metadata error")
    } noraise {
      _ => fail("accepted changed metadata")
    }
    assert_eq(@host.fetch_delta_reference(base + "/ok", pin).to_bytes(), data)
    ignore(@http.get(base + "/stop"))
    serving.wait()
  })
}
