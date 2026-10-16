///|
async test "external range metadata is validated before every artifact write and can recover after refusal" {
  let data = b"abc"
  let spec = audit_spec(data)
  let good : @host.ReceivedBlock = {
    bytes: data,
    status: 206,
    etag: spec.etag,
    range: { start: 0L, end: 3L, },
    total: 3L,
    content_encoding: "identity",
  }
  let dir = @fs.tmpdir(prefix="moonfetchledger-source-validation-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  for
    bad in [
      { ..good, status: 200, },
      { ..good, etag: "\"other\"", },
      { ..good, range: { start: 1L, end: 3L, }, },
      { ..good, total: 4L, },
      { ..good, content_encoding: "gzip", },
      { ..good, bytes: b"ab", },
      { ..good, bytes: b"abcd", },
    ] {
    let mut calls = 0
    try
      @host.receive_from(spec, path, chunk_size=3, fetch_range=_ => {
        calls += 1
        bad
      })
    catch {
      @ledger.InvalidResponse(_) => ()
      _ => fail("incorrect external response refusal")
    } noraise {
      _ => fail("wrote unsupported external data")
    }
    assert_eq(calls, 1)
    assert_eq(@fs.read_file(path).binary(), b"")
    assert_eq(
      @fs.read_file(path + ".mfl").text(),
      @ledger.Session::new(spec, chunk_size=3).checkpoint(),
    )
  }
  assert_true(
    @host.receive_from(spec, path, chunk_size=3, fetch_range=_ => good).complete,
  )
  assert_eq(@fs.read_file(path).binary(), data)
}

///|
async test "external range source shares checkpoint pause repair and zero-fetch reopen" {
  let data = b"abcdefg"
  let spec = @ledger.ObjectSpec::new(
    "fixture:external-source",
    7L,
    "\"v1\"",
    @ledger.digest(data),
  )
  let dir = @fs.tmpdir(prefix="moonfetchledger-external-source-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let requested : Array[Int64] = []
  let source = async fn(range : @ledger.ByteRange) -> @host.ReceivedBlock {
    @async.sleep(0)
    requested.push(range.start)
    {
      bytes: data[range.start.to_int():range.end.to_int()].to_owned(),
      status: 206,
      etag: spec.etag,
      range,
      total: 7L,
      content_encoding: "identity",
    }
  }
  let paused = @host.receive_from(
    spec,
    path,
    fetch_range=source,
    chunk_size=3,
    parallel=1,
    stop_after_blocks=2,
  )
  assert_true(!paused.complete)
  let file = @fs.open(path, mode=ReadWrite)
  file.write_at(b"X", position=1L)
  file.close()
  let resumed = @host.receive_from(spec, path, fetch_range=source, parallel=1)
  assert_true(resumed.complete)
  assert_eq(resumed.recovery.retained_bytes, 3L)
  assert_eq(resumed.downloaded_blocks, 2)
  assert_eq(requested, [0L, 3L, 0L, 6L])
  assert_eq(@fs.read_file(path).binary(), data)
  let saved = @fs.read_file(path + ".mfl").binary()
  assert_eq(
    @host.receive_from(spec, path, fetch_range=source).downloaded_blocks,
    0,
  )
  assert_eq(@fs.read_file(path + ".mfl").binary(), saved)
  assert_eq(requested, [0L, 3L, 0L, 6L])
}
