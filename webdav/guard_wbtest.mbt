///|
fn test_spec(bytes : Bytes) -> @ledger.ObjectSpec raise {
  @ledger.ObjectSpec::new(
    "https://example.test/dav/file",
    bytes.length().to_int64(),
    "\"v1\"",
    @ledger.digest(bytes),
  )
}

///|
fn reply(
  bytes : Bytes,
  range : String,
  total_length : Int32,
  status~ : Int32 = 206,
  extra~ : Array[(String, String)] = [],
) -> @transport.RawResponse {
  let headers = @headers.Headers::from_pairs([
    ("ETag", "\"v1\""),
    ("Content-Range", range),
    ("Content-Length", total_length.to_string()),
  ]).merge(@headers.Headers::from_pairs(extra))
  {
    status,
    status_text: "fixture",
    headers,
    body: @transport.ResponseBody::from_bytes(bytes),
    set_cookies: [],
  }
}

///|
fn mocked(
  spec : @ledger.ObjectSpec,
  inner : &@transport.Transport,
) -> Source raise {
  make_source(
    spec,
    {
      base_url: "https://example.test/dav",
      username: Some("fixture"),
      password: Some("public-fixture-password"),
      timeout_ms: Some(5000),
      retry_on_423: None,
    },
    "file",
    inner,
    false,
  )
}

///|
async test "WebDAV source uses actual upstream GET range conditional auth and guarded representation" {
  let data = b"abcdefg"
  let spec = test_spec(data)
  let mock = @transport.MockTransport::from_responses([
    reply(b"abc", "bytes 0-2/7", 3),
    reply(b"def", "bytes 3-5/7", 3),
    reply(b"g", "bytes 6-6/7", 1),
  ])
  let source = mocked(spec, mock)
  let dir = @fs.tmpdir(prefix="moonfetchledger-dav-mock-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/file"
  assert_true(source.receive(path, chunk_size=3, parallel=1).complete)
  assert_eq(@fs.read_file(path).binary(), data)
  assert_eq(mock.request_count(), 3)
  let requests = mock.received()
  assert_eq(requests.map(r => r.headers.get("Range")), [
    Some("bytes=0-2"),
    Some("bytes=3-5"),
    Some("bytes=6-6"),
  ])
  for request in requests {
    assert_eq(request.url, spec.resource)
    assert_eq(request.headers.get("If-Match"), Some(spec.etag))
    assert_eq(request.headers.get("Accept-Encoding"), Some("identity"))
    assert_true(
      request.headers.get("Authorization").unwrap().has_prefix("Basic "),
    )
  }
  let saved = @fs.read_file(path + ".mfl").text()
  assert_true(
    !saved.contains("public-fixture-password") && !saved.contains("Basic "),
  )
  assert_eq(source.receive(path).downloaded_blocks, 0)
  assert_eq(mock.request_count(), 3)
}

///|
async test "WebDAV refuses unverified representations without content writes and then recovers" {
  let spec = test_spec(b"abc")
  let dir = @fs.tmpdir(prefix="moonfetchledger-dav-refusal-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/file"
  let mut count = 0
  for
    bad in [
      reply(b"abc", "bytes 0-2/3", 3, status=200),
      reply(b"abc", "bytes 0-2/3", 3, status=302, extra=[
        ("Location", "https://other.test/secret"),
      ]),
      reply(b"abc", "bytes 0-2/3", 3, extra=[("ETag", "\"other\"")]),
      reply(b"abc", "bytes 1-3/4", 3),
      reply(b"abc", "bytes 0-2/*", 3),
      reply(b"abc", "bytes 0-2/3", 3, extra=[("Content-Encoding", "gzip")]),
      reply(b"abc", "bytes 0-2/3", 3, extra=[
        ("Content-Type", "Multipart/byteranges; boundary=x"),
      ]),
      reply(b"abc", "bytes 0-2/3", 3, extra=[
        ("Content-Type", " \t multipart/byteranges; boundary=x"),
      ]),
      reply(b"abc", "bytes 0-2/3", 4),
      reply(b"ab", "bytes 0-2/3", 3),
      reply(b"abcd", "bytes 0-2/3", 3),
    ] {
    let mock = @transport.MockTransport::new(bad)
    let source = mocked(spec, mock)
    try source.receive(path, chunk_size=3, parallel=1) catch {
      RequestFailed(message) => assert_true(message.contains("require 206"))
      _ => fail("incorrect WebDAV representation diagnostic")
    } noraise {
      _ => fail("accepted invalid WebDAV representation")
    }
    assert_eq(mock.request_count(), 1)
    assert_eq(@fs.read_file(path).binary(), b"")
    assert_eq(
      @fs.read_file(path + ".mfl").text(),
      @ledger.Session::new(spec, chunk_size=3).checkpoint(),
    )
    count += 1
  }
  assert_eq(count, 11)
  let good = mocked(
    spec,
    @transport.MockTransport::new(reply(b"abc", "bytes 0-2/3", 3)),
  )
  assert_true(good.receive(path, parallel=1).complete)
  assert_eq(@fs.read_file(path).binary(), b"abc")
}

///|
async test "WebDAV transport diagnostics cannot reflect credentials into public errors" {
  @async.sleep(0)
  let source = mocked(
    test_spec(b"abc"),
    @transport.MockTransport::failing(
      @transport.TransportError::Network(
        "untrusted reflected public-fixture-password",
      ),
    ),
  )
  let dir = @fs.tmpdir(prefix="moonfetchledger-dav-redaction-")
  defer @fs.rmdir(dir, recursive=true)
  try source.receive(dir + "/file") catch {
    RequestFailed(message) =>
      assert_true(!message.contains("public-fixture-password"))
    _ => fail("incorrect WebDAV transport error")
  } noraise {
    _ => fail("invented a successful response")
  }
}

///|
async test "WebDAV retains exactly the valid sparse coverage for every three-block mask" {
  let data = b"abcdefg"
  let spec = test_spec(data)
  let dir = @fs.tmpdir(prefix="moonfetchledger-dav-masks-")
  defer @fs.rmdir(dir, recursive=true)
  for mask in 0..<8 {
    let path = dir + "/file" + mask.to_string()
    let session = @ledger.Session::new(spec, chunk_size=3)
    let responses = []
    let wanted : Array[String?] = []
    while session.reserve_missing() is Some(lease) {
      let range = lease.range
      let bytes = data[range.start.to_int():range.end.to_int()].to_owned()
      let index = range.start.to_int() / 3
      if (mask & (1 << index)) != 0 {
        let prepared = session.prepare_chunk(
          lease,
          bytes,
          status=206,
          etag=spec.etag,
          range~,
          total=7L,
        )
        session.commit_written(prepared, bytes)
      } else {
        responses.push(
          reply(
            bytes,
            "bytes \{range.start}-\{range.end - 1L}/7",
            bytes.length(),
          ),
        )
        wanted.push(Some("bytes=\{range.start}-\{range.end - 1L}"))
      }
    }
    @fs.write_file(path, data)
    @fs.write_file(path + ".mfl", session.checkpoint())
    let mock = @transport.MockTransport::from_responses(responses)
    assert_true(mocked(spec, mock).receive(path, parallel=1).complete)
    assert_eq(mock.received().map(r => r.headers.get("Range")), wanted)
    assert_eq(@fs.read_file(path).binary(), data)
    assert_true(@host.audit(spec, path).complete)
  }
}
