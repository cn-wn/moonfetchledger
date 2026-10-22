///|
async test "signed artifact credentials remain resource-bound before staging and are never persisted" {
  let dir = @fs.tmpdir(prefix="mfl-signed-binding-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFabc!", 3)
  let trust = release_trust()
  let signed = release_bytes(2L, pin=@ledger.digest(reference.to_bytes()))
  let state = dir + "/state"
  let output = dir + "/staging"
  let old = dir + "/old"
  @fs.write_file(old, b"!DEFabc")
  @host.initialize_release_state(state, trust)
  let wrong = @host.BearerAuth::new(
    "https://other.test/artifact", "private-fixture-value",
  )
  try
    @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      metadata_file=dir + "/delta",
      seed=old,
      auth=wrong,
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong signed credential binding error")
  } noraise {
    _ => fail("accepted different credential destination")
  }
  assert_true(!@fs.exists(output) && !@fs.exists(output + ".mfl.lock"))
  let correct = @host.BearerAuth::new(
    reference.spec.resource,
    "private-fixture-value",
  )
  let report = @host.update_signed_release(
    signed,
    trust,
    state,
    output,
    now=121L,
    metadata_file=dir + "/delta",
    seed=old,
    auth=correct,
  )
  assert_true(report.update.receive.complete)
  assert_eq(report.update.receive.downloaded_blocks, 0)
  for path in [state, output + ".mfl", dir + "/delta"] {
    assert_true(!@fs.read_file(path).text().contains("private-fixture-value"))
  }
}

///|
async test "signed private update preserves progress on expired credential and resumes with rotated token" {
  let dir = @fs.tmpdir(prefix="mfl-signed-private-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEFghi!"
  let state = dir + "/state"
  let output = dir + "/staging"
  let old = dir + "/old"
  @fs.write_file(old, b"!abc")
  let trust = release_trust()
  @host.initialize_release_state(state, trust)
  let mut expected = "private-one"
  let mut denied = 0
  let ranges : Array[Int32] = []
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
          assert_eq(request.path, "/artifact")
          if request.headers.get("Authorization") != Some("Bearer " + expected) {
            denied += 1
            conn.send_response(401, "Unauthorized", extra_headers={
              "Content-Length": "0",
              "Connection": "close",
            })
            conn.end_response()
            return
          }
          let bounds = request.headers.get("Range").unwrap()[6:]
            .split("-")
            .collect()
          let start = @strconv.parse_int(bounds[0])
          let end = @strconv.parse_int(bounds[1]) + 1
          ranges.push(start)
          conn.send_response(206, "Partial Content", extra_headers={
            "Content-Length": "\{end-start}",
            "Content-Range": "bytes \{start}-\{end-1}/10",
            "ETag": "\"v2\"",
            "Connection": "close",
          })
          conn.write(data[start:end].to_owned())
          conn.end_response()
        })
      }
    })
    let spec = @ledger.ObjectSpec::new(
      base + "/artifact",
      10L,
      "\"v2\"",
      @ledger.digest(data),
    )
    let indexer = @ledger.DeltaIndexer::new(spec, chunk_size=3)
    while indexer.next_range() is Some(r) {
      indexer.push(data[r.start.to_int():r.end.to_int()].to_owned())
    }
    let metadata = indexer.finish().to_bytes()
    @fs.write_file(dir + "/delta", metadata)
    let signed = release_bytes(2L, pin=@ledger.digest(metadata))
    let first = @host.BearerAuth::new(
      spec.resource,
      "private-one",
      allow_loopback_http=true,
    )
    let paused = @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=120L,
      seed=old,
      metadata_file=dir + "/delta",
      parallel=1,
      stop_after_blocks=1,
      auth=first,
    )
    assert_true(!paused.update.receive.complete)
    assert_eq(paused.update.receive.confirmed_bytes, 7L)
    let saved = @fs.read_file(output + ".mfl").binary()
    let bytes = @fs.read_file(output).binary()
    expected = "private-two"
    try
      @host.update_signed_release(
        signed,
        trust,
        state,
        output,
        now=121L,
        resuming=true,
        metadata_file=dir + "/delta",
        parallel=1,
        max_attempts=3,
        auth=first,
      )
    catch {
      @host.InvalidResponse(message) =>
        assert_true(
          message.contains("HTTP 401") && !message.contains("private-one"),
        )
      _ => fail("wrong expired private credential error")
    } noraise {
      _ => fail("accepted expired token")
    }
    assert_eq(denied, 1)
    assert_eq(@fs.read_file(output).binary(), bytes)
    assert_eq(@fs.read_file(output + ".mfl").binary(), saved)
    let rotated = @host.BearerAuth::new(
      spec.resource,
      "private-two",
      allow_loopback_http=true,
    )
    let complete = @host.update_signed_release(
      signed,
      trust,
      state,
      output,
      now=122L,
      resuming=true,
      metadata_file=dir + "/delta",
      parallel=1,
      auth=rotated,
      export_to=dir + "/ready",
    )
    assert_true(complete.update.receive.complete && complete.update.exported)
    assert_eq(complete.update.receive.downloaded_blocks, 1)
    assert_eq(ranges, [3, 6])
    assert_eq(@fs.read_file(dir + "/ready").binary(), data)
    for path in [state, output + ".mfl", dir + "/delta"] {
      let text = @fs.read_file(path).text()
      assert_true(
        !text.contains("private-one") && !text.contains("private-two"),
      )
    }
    ignore(@http.get(base + "/stop"))
    serving.wait()
  })
}
