///|
async test "signed update preserves state on signature and control errors then delivers and resumes offline" {
  let dir = @fs.tmpdir(prefix="mfl-signed-update-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFabc!", 3)
  let pin = @ledger.digest(reference.to_bytes())
  let signed = release_bytes(2L, pin~)
  let trust = release_trust()
  let state = dir + "/state"
  let seed = dir + "/old"
  let output = dir + "/new"
  @fs.write_file(seed, b"!DEFabc")
  @host.initialize_release_state(state, trust)
  let initial = @fs.read_file(state).binary()
  for
    (parallel, timeout, resuming) in [
      (0, 1, false),
      (17, 1, false),
      (1, 0, false),
      (1, 120001, false),
      (1, 1, true),
    ] {
    try
      @host.update_signed_release(
        signed,
        trust,
        state,
        output,
        now=120L,
        seed~,
        metadata_file=dir + "/delta",
        parallel~,
        request_timeout_ms=timeout,
        resuming~,
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong signed preflight rejection")
    } noraise {
      _ => fail("accepted invalid signed controls")
    }
    assert_eq(@fs.read_file(state).binary(), initial)
  }
  for path in [state, state + ".lock", state + ".next", dir + "/./state"] {
    try
      @host.update_signed_release(
        signed,
        trust,
        state,
        path,
        now=120L,
        seed~,
        metadata_file=dir + "/delta",
      )
    catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong protected state alias error")
    } noraise {
      _ => fail("used release state as staging")
    }
    assert_eq(@fs.read_file(state).binary(), initial)
  }
  let tampered = @utf8.encode(
    @utf8.decode(signed).replace_all(old="datasets", new="forged"),
  )
  try
    @host.update_signed_release(tampered, trust, state, output, now=120L, seed~)
  catch {
    @release.UntrustedRelease(_) => ()
    _ => fail("wrong signature error")
  } noraise {
    _ => fail("accepted forged release")
  }
  assert_eq(@fs.read_file(state).binary(), initial)
  assert_true(!@fs.exists(output))
  let result = @host.update_signed_release(
    signed,
    trust,
    state,
    output,
    now=120L,
    seed~,
    metadata_file=dir + "/delta",
    export_to=dir + "/ready",
  )
  assert_eq(result.version, 2L)
  assert_true(result.update.receive.complete && result.update.exported)
  assert_eq(result.update.receive.downloaded_blocks, 0)
  assert_eq(@fs.read_file(dir + "/ready").binary(), b"abcDEFabc!")
  let resumed = @host.update_signed_release(
    signed,
    trust,
    state,
    output,
    now=121L,
    resuming=true,
    metadata_file=dir + "/delta",
  )
  assert_eq(resumed.update.receive.downloaded_blocks, 0)
  let saved = @fs.read_file(state).binary()
  try
    @host.update_signed_release(
      release_bytes(1L, pin~),
      trust,
      state,
      output,
      now=122L,
      resuming=true,
      metadata_file=dir + "/delta",
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong signed rollback result")
  } noraise {
    _ => fail("accepted signed rollback")
  }
  assert_eq(@fs.read_file(state).binary(), saved)
  assert_eq(@fs.read_file(seed).binary(), b"!DEFabc")
}

///|
async test "bounded release and key files and no-replace signing preserve private seed and unrelated paths" {
  let dir = @fs.tmpdir(prefix="mfl-sign-files-")
  defer @fs.rmdir(dir, recursive=true)
  let private_path = dir + "/private"
  let public_path = dir + "/public"
  let destination = dir + "/release"
  @fs.write_file(private_path, release_seed())
  @fs.write_file(public_path, @ed25519.derive_public_key(release_seed()))
  let trust = @host.load_release_trust(public_path, "datasets", "stable")
  let descriptor = @release.Release::new(
    "datasets",
    "stable",
    2L,
    100L,
    200L,
    "https://example.test/delta",
    @ledger.digest(b"delta"),
  )
  @host.write_signed_release(descriptor, private_path, destination)
  let bytes = @host.load_release(destination)
  assert_eq(trust.verify(bytes, 120L).release.version, 2L)
  assert_eq(bytes, descriptor.sign(release_seed()))
  for path in [destination, private_path, public_path] {
    let before = @fs.read_file(path).binary()
    try @host.write_signed_release(descriptor, private_path, path) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong signer destination error")
    } noraise {
      _ => fail("replaced key or descriptor")
    }
    assert_eq(@fs.read_file(path).binary(), before)
  }
  @fs.write_file(dir + "/occupied.next", b"foreign")
  try
    @host.write_signed_release(descriptor, private_path, dir + "/occupied")
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong temporary collision")
  } noraise {
    _ => fail("replaced existing temporary")
  }
  assert_eq(@fs.read_file(dir + "/occupied.next").binary(), b"foreign")
  for size in [0, 31, 33] {
    @fs.write_file(dir + "/bad-key", Bytes::make(size, b'x'))
    try @host.load_release_trust(dir + "/bad-key", "datasets", "stable") catch {
      @host.InvalidInput(_) | @release.InvalidRelease(_) => ()
      _ => fail("wrong key size error")
    } noraise {
      _ => fail("accepted wrong key size")
    }
  }
  @fs.write_file(dir + "/large", Bytes::make(16385, b'x'))
  try @host.load_release(dir + "/large") catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong announcement size error")
  } noraise {
    _ => fail("loaded oversized announcement")
  }
  assert_eq(@fs.read_file(private_path).binary(), release_seed())
}

///|
async test "release HTTP boundary refuses redirects encoded ranges and oversized bodies then allows exact-bound retry" {
  let mut traps = 0
  let received : Array[String] = []
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let base = "http://127.0.0.1:\{server.addr.port()}"
    let serving = group.spawn(() => {
      while true {
        let (conn, _) = server.accept()
        let request = conn.read_request() catch {
          @io.ReaderClosed => {
            conn.close()
            continue
          }
          e => raise e
        }
        received.push(request.path)
        if request.path == "/stop" {
          conn.send_response(200, "OK", extra_headers={
            "Content-Length": "0",
            "Connection": "close",
          })
          conn.end_response()
          conn.close()
          break
        }
        group.spawn_bg(allow_failure=true, () => {
          defer conn.close()
          let headers : @http.Headers = { "Connection": "close" }
          if request.path == "/trap" {
            traps += 1
          }
          if request.path == "/redirect" {
            headers["Location"] = base + "/trap"
            headers["Content-Length"] = "0"
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
          if request.path == "/declared" {
            headers["Content-Length"] = "16385"
          }
          conn.send_response(200, "OK", extra_headers=headers)
          if request.path == "/declared" {
            conn.flush()
          }
          if request.path != "/declared" {
            conn.write(
              Bytes::make(
                if request.path == "/stream" {
                  16385
                } else {
                  16384
                },
                b'x',
              ),
            )
          }
          conn.end_response()
        })
      }
    })
    // A connector may establish and abandon a socket before sending a request.
    // It must not kill the origin or count as an actual HTTP request.
    let abandoned = @socket.Tcp::connect(
      @socket.Addr::parse("127.0.0.1:\{server.addr.port()}"),
    )
    abandoned.close()
    for suffix in ["/redirect", "/encoded", "/range", "/declared", "/stream"] {
      try @host.fetch_release(base + suffix) catch {
        @host.InvalidResponse(message) =>
          if suffix == "/declared" || suffix == "/stream" {
            assert_true(message.contains("exceeds 16384"))
          } else {
            assert_true(message.contains("unencoded 200"))
          }
        _ => fail("wrong release HTTP rejection")
      } noraise {
        _ => fail("accepted unsupported release response")
      }
    }
    assert_eq(traps, 0)
    assert_eq(@host.fetch_release(base + "/ok"), Bytes::make(16384, b'x'))
    ignore(
      @http.get(base + "/stop") catch {
        e => fail("release fixture stop: \{Repr(e)}")
      },
    )
    serving.wait()
    assert_eq(received, [
      "/redirect", "/encoded", "/range", "/declared", "/stream", "/ok", "/stop",
    ])
  })
}
