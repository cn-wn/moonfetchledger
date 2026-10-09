///|
test "Bearer token grammar and explicit transport bounds refuse unsupported input" {
  ignore(@host.BearerAuth::new("https://example.test/data", "a".repeat(4096)))
  for
    token in [
      "",
      "=",
      "a=b",
      "a b",
      "a\r\nInjected:x",
      "é",
      "\"quoted\"",
      "a:",
      "a".repeat(4097),
    ] {
    try @host.BearerAuth::new("https://example.test/data", token) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect token validation diagnostic")
    } noraise {
      _ => fail("accepted malformed token")
    }
  }
  for token in ["a", "Ab09-._~+/=="] {
    ignore(@host.BearerAuth::new("https://example.test:443/data?q=1", token))
  }
  for
    url in [
      "http://127.0.0.1/data",
      "http://example.test/data",
      "https://user@host/data",
      "https:///data",
      "https://[::1]/data",
      "https://host:0/data",
      "https://host:65536/data",
      "https://host:01/data",
      "https://host:no/data",
      "https://host/data#fragment",
      "https://host/space here",
      "https://host/é",
      "https://host\\evil/data",
      "https://-host/data",
      "https://host..test/data",
      "https://host?query",
      "ftp://host/data",
      "https://host/" + "a".repeat(8192),
    ] {
    try @host.BearerAuth::new(url, "private-fixture-token") catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect authenticated URL diagnostic")
    } noraise {
      _ => fail("accepted unsupported authenticated URL")
    }
  }
  ignore(
    @host.BearerAuth::new(
      "http://127.0.0.1:8080/data",
      "a",
      allow_loopback_http=true,
    ),
  )
  for
    url in [
      "http://localhost/data", "http://127.0.0.2/data", "http://127.0.0.1.evil/data",
    ] {
    try @host.BearerAuth::new(url, "a", allow_loopback_http=true) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect loopback diagnostic")
    } noraise {
      _ => fail("allowed credentials outside literal loopback")
    }
  }
}

///|
async test "resource binding fails before files are created" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-auth-binding-")
  defer @fs.rmdir(dir, recursive=true)
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/data",
    3L,
    "\"v1\"",
    @ledger.digest(b"abc"),
  )
  let auth = @host.BearerAuth::new(
    "https://other.test/data", "private-fixture-token",
  )
  try @host.download(spec, dir + "/output", auth~) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect resource binding diagnostic")
  } noraise {
    _ => fail("sent credentials to a different resource")
  }
  assert_eq(@fs.readdir(dir).length(), 0)
}

///|
async test "credential rotation retains coverage, 401 never retries and 302 never follows" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-auth-http-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdefg"
  let path = dir + "/data"
  let token1 = "fixture-token-one"
  let token2 = "fixture-token-two"
  let mut expected = token1
  let requested : Array[String] = []
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let url = "http://127.0.0.1:\{server.addr.port()}"
    let serving = group.spawn(() => {
      for _ in 0..<6 {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        requested.push(request.path)
        if request.path == "/redirect" {
          conn.send_response(302, "Found", extra_headers={
            "Location": url + "/data",
            "Connection": "close",
          })
        } else if request.headers.get("Authorization") !=
          Some("Bearer " + expected) {
          conn.send_response(401, "Unauthorized", extra_headers={
            "Connection": "close",
          })
        } else {
          let bounds = request.headers.get("Range").unwrap()[6:]
            .split("-")
            .collect()
          let start = @strconv.parse_int(bounds[0])
          let end = @strconv.parse_int(bounds[1]) + 1
          assert_eq(request.headers.get("If-Range"), Some("\"v1\""))
          conn.send_response(206, "Partial Content", extra_headers={
            "ETag": "\"v1\"",
            "Content-Range": "bytes \{start}-\{end - 1}/7",
            "Connection": "close",
          })
          conn.write(data[start:end].to_owned())
        }
        conn.end_response()
      }
    })
    let spec = @ledger.ObjectSpec::new(
      url + "/data",
      7L,
      "\"v1\"",
      @ledger.digest(data),
    )
    try
      @host.download(spec, path, chunk_size=3, parallel=1, max_attempts=3)
    catch {
      @host.InvalidResponse(_) => ()
      _ => fail("incorrect unauthenticated diagnostic")
    } noraise {
      _ => fail("private server accepted missing credential")
    }
    assert_eq(requested.length(), 1)
    let auth1 = @host.BearerAuth::new(
      spec.resource,
      token1,
      allow_loopback_http=true,
    )
    assert_true(
      !@host.download(spec, path, parallel=1, stop_after_blocks=1, auth=auth1).complete,
    )
    let checkpoint = @fs.read_file(path + ".mfl").text()
    assert_true(!checkpoint.contains(token1) && !checkpoint.contains(token2))
    expected = token2
    try
      @host.download(spec, path, parallel=1, max_attempts=3, auth=auth1)
    catch {
      @host.InvalidResponse(message) => {
        assert_true(message.contains("HTTP 401"))
        assert_true(!message.contains(token1))
      }
      _ => fail("incorrect expired credential diagnostic")
    } noraise {
      _ => fail("accepted expired credential")
    }
    assert_eq(requested.length(), 3)
    assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
    let auth2 = @host.BearerAuth::new(
      spec.resource,
      token2,
      allow_loopback_http=true,
    )
    let report = @host.download(spec, path, parallel=1, auth=auth2)
    assert_true(report.complete)
    assert_eq(report.recovery.retained_bytes, 3L)
    assert_eq(report.downloaded_blocks, 2)
    assert_eq(@fs.read_file(path).binary(), data)
    let redirected = @ledger.ObjectSpec::new(
      url + "/redirect",
      7L,
      "\"v1\"",
      @ledger.digest(data),
    )
    try
      @host.download(
        redirected,
        dir + "/redirect",
        parallel=1,
        auth=@host.BearerAuth::new(
          redirected.resource,
          token2,
          allow_loopback_http=true,
        ),
      )
    catch {
      @host.InvalidResponse(_) => ()
      _ => fail("incorrect redirect diagnostic")
    } noraise {
      _ => fail("followed credential-bearing redirect")
    }
    serving.wait()
    assert_eq(requested.length(), 6)
    assert_eq(requested[5], "/redirect")
    assert_eq(@fs.file_size(dir + "/redirect"), 0L)
  })
}
