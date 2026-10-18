///|
// This finite loopback fixture implements only PUT/GET/OPTIONS for one artifact.
// The published upstream client handles real requests, framing, auth and paths;
// this sample does not claim RFC 4918 server conformance or vendor compatibility.
async fn main {
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let sha256 = "dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042"
  assert_eq(@ledger.digest(data), sha256)
  let dir = @fs.tmpdir(prefix="moonfetchledger-webdav-demo-")
  defer @fs.rmdir(dir, recursive=true)
  let output = dir + "/earthquakes.csv"
  let ready = dir + "/ready.csv"
  let requested : Array[Int32] = []
  let mut full_gets = 0
  let mut resume_probes = 0
  let mut wire_requests = 0
  let mut uploads = 0
  let mut stored : Bytes? = None
  let mut encoded = false
  @async.with_task_group(group => {
    let server = @http.Server::Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let origin = "http://127.0.0.1:\{server.addr.port()}"
    let endpoint = origin + "/dav"
    let etag = "\"fixture-v1\""
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
          assert_eq(request.path, "/dav/earthquakes.csv")
          wire_requests += 1
          let authorization = "Basic " +
            @base64.encode(b"fixture:public-webdav-test-password")
          assert_eq(request.headers.get("Authorization"), Some(authorization))
          if request.meth == Put {
            let body = conn.read_all().binary()
            assert_eq(body, data)
            stored = Some(body)
            uploads += 1
            conn.send_response(201, "Created", extra_headers={
              "ETag": etag,
              "Connection": "close",
            })
            conn.end_response()
          } else if request.meth == Options {
            conn.send_response(200, "OK", extra_headers={
              "DAV": "1",
              "Allow": "OPTIONS, GET, PUT",
              "Connection": "close",
            })
            conn.end_response()
          } else {
            assert_eq(request.meth, Get)
            let artifact = stored.unwrap()
            if request.headers.get("Range") is Some(header) {
              if header == "bytes=28008-" {
                // A legal unsatisfied suffix request for a full-length file.
                // The upstream resume API uses length as its completion test.
                assert_eq(request.headers.get("If-Range"), Some(etag))
                resume_probes += 1
                conn.send_response(416, "Range Not Satisfiable", extra_headers={
                  "Content-Range": "bytes */28008",
                  "ETag": etag,
                  "Connection": "close",
                })
                conn.end_response()
                return
              }
              assert_eq(request.headers.get("If-Match"), Some(etag))
              assert_eq(
                request.headers.get("Accept-Encoding"),
                Some("identity"),
              )
              let bounds = header[6:].split("-").collect()
              let start = @strconv.parse_int(bounds[0])
              let end = @strconv.parse_int(bounds[1]) + 1
              requested.push(start / 4096)
              let rejected_encoding = encoded
              conn.send_response(206, "Partial Content", extra_headers={
                "ETag": etag,
                "Content-Range": "bytes \{start}-\{end - 1}/28008",
                "Content-Encoding": if encoded {
                  "gzip"
                } else {
                  "identity"
                },
                "Connection": "close",
              })
              try {
                conn.write(artifact[start:end].to_owned())
                conn.end_response()
              } catch {
                error =>
                  // A correct client closes immediately after refusing this
                  // deliberately encoded header. Only this fixture branch may
                  // ignore the resulting body-write/peer-close error.
                  if !rejected_encoding {
                    raise error
                  }
              }
            } else {
              full_gets += 1
              conn.send_response(200, "OK", extra_headers={
                "ETag": etag,
                "Connection": "close",
              })
              conn.write(artifact)
              conn.end_response()
            }
          }
        })
      }
    })
    let config : @upstream.WebdavConfig = {
      base_url: endpoint,
      username: Some("fixture"),
      password: Some("public-webdav-test-password"),
      timeout_ms: Some(5000),
      retry_on_423: None,
    }
    let client = @upstream.create_webdav_client(config)
    let published = client.put_file(path="/earthquakes.csv", data~)
    assert_eq(published.etag, Some(etag))
    assert_true(client.options(path="/earthquakes.csv").supports("GET"))
    // The existing ecosystem client performs the original complete download.
    client.download_to_path(path="/earthquakes.csv", local_path=output)
    assert_eq(@fs.read_file(output).binary(), data)
    assert_eq(uploads, 1)
    assert_eq(full_gets, 1)
    println("upstream: published and downloaded all 28008 fixture bytes")
    let spec = @ledger.ObjectSpec::new(
      endpoint + "/earthquakes.csv",
      28008L,
      etag,
      sha256,
    )
    // In this fixture the publisher independently knows the original bytes and
    // trusted whole digest. Consumers must receive this pin through trusted input.
    let reference_path = dir + "/release.blocks.mfl"
    let reference_pin = @host.write_block_reference(
      spec,
      "fixtures/earthquakes-2024-01-01.csv",
      reference_path,
      chunk_size=4096,
    )
    let reference = @host.load_block_reference(
      spec, reference_path, reference_pin,
    )
    @host.adopt(spec, output, chunk_size=4096)
    assert_true(requested.is_empty())
    println("ledger: trusted adoption completed without range requests")
    let source = @dav.Source::new(
      spec,
      config,
      "/earthquakes.csv",
      allow_loopback_auth=true,
    )
    let file = @fs.open(output, mode=ReadWrite)
    file.write_at(b"\x00", position=8195L)
    file.sync()
    file.close()
    let damaged = @fs.read_file(output).binary()
    assert_eq(damaged.length(), data.length())
    assert_true(damaged != data)
    let checkpoint = @fs.read_file(output + ".mfl").binary()
    let audit = @host.audit(spec, output)
    assert_eq(audit.confirmed_bytes, 23912L)
    assert_eq(audit.invalidated, [{ start: 8192L, end: 12288L, }])
    assert_eq(@fs.read_file(output + ".mfl").binary(), checkpoint)
    assert_eq(@fs.read_file(output).binary(), damaged)
    assert_true(requested.is_empty())
    println(
      "audit: same-size corruption detected; retained=23912; no network or content writes",
    )
    // Even though get_file hides Content-Encoding, the transport guard refuses
    // unsupported raw representations before any artifact content is written.
    encoded = true
    try source.receive(output, parallel=1) catch {
      @dav.RequestFailed(_) => ()
      _ => fail("incorrect encoded WebDAV response diagnostic")
    } noraise {
      _ => fail("accepted an encoded range")
    }
    assert_eq(@fs.read_file(output).binary(), damaged)
    assert_eq(requested, [2])
    encoded = false
    let repaired = source.receive(output, parallel=1)
    assert_true(repaired.complete)
    assert_eq(repaired.recovery.retained_bytes, 23912L)
    assert_eq(repaired.downloaded_blocks, 1)
    assert_eq(requested, [2, 2])
    assert_eq(@fs.read_file(output).binary(), data)
    // Two nonadjacent bad blocks remain repairable over a paused/reopened call.
    let holes = @fs.open(output, mode=ReadWrite)
    holes.write_at(b"\x00", position=4101L)
    holes.write_at(b"\x00", position=20485L)
    holes.sync()
    holes.close()
    let paused = source.receive(output, parallel=1, stop_after_blocks=1)
    assert_true(!paused.complete)
    assert_eq(paused.recovery.retained_bytes, 19816L)
    assert_eq(paused.confirmed_bytes, 23912L)
    let reopened = @dav.Source::new(
      spec,
      config,
      "earthquakes.csv",
      allow_loopback_auth=true,
    )
    let resumed = reopened.receive(output, parallel=1)
    assert_true(resumed.complete)
    assert_eq(resumed.recovery.retained_bytes, 23912L)
    assert_eq(resumed.downloaded_blocks, 1)
    assert_eq(requested, [2, 2, 1, 5])
    assert_eq(full_gets, 1)
    assert_eq(@fs.read_file(output).binary(), data)
    @host.export_verified(spec, output, ready)
    assert_eq(@fs.read_file(ready).binary(), data)
    // Losing local progress must not force a complete redownload or trust a
    // damaged artifact. Only the independent publisher reference supplies hashes.
    @fs.remove(output + ".mfl")
    let lost = @fs.open(output, mode=ReadWrite)
    lost.write_at(b"\x00", position=16387L)
    lost.sync()
    lost.close()
    let damaged_without_checkpoint = @fs.read_file(output).binary()
    let reference_bytes = @fs.read_file(reference_path).binary()
    let requests_before = requested.length()
    client.download_to_path_resume(
      path="/earthquakes.csv",
      local_path=output,
      etag~,
    )
    assert_eq(resume_probes, 1)
    assert_eq(@fs.read_file(output).binary(), damaged_without_checkpoint)
    assert_eq(@fs.file_size(output), 28008L)
    println(
      "upstream boundary: same-size corrupt artifact; documented 416/total-length resume returned successfully, while content remains damaged",
    )
    let wire_before_reference = wire_requests
    try @host.adopt(spec, output, chunk_size=4096) catch {
      @ledger.DigestMismatch(_) => ()
      _ => fail("ordinary adoption must require complete correct content")
    } noraise {
      _ => fail("trusted damaged content without a block reference")
    }
    assert_true(!@fs.exists(output + ".mfl"))
    let independently_audited = @host.audit_with_reference(reference, output)
    assert_eq(independently_audited.confirmed_bytes, 23912L)
    assert_eq(independently_audited.invalidated, [
      { start: 16384L, end: 20480L, },
    ])
    assert_true(!@fs.exists(output + ".mfl"))
    let rebuilt = @host.adopt_with_reference(reference, output)
    assert_eq(rebuilt.to_json(), independently_audited.to_json())
    assert_eq(@fs.read_file(output).binary(), damaged_without_checkpoint)
    assert_eq(@fs.read_file(reference_path).binary(), reference_bytes)
    assert_eq(requested.length(), requests_before)
    assert_eq(wire_requests, wire_before_reference)
    let reference_repaired = reopened.receive(output, parallel=1)
    assert_true(reference_repaired.complete)
    assert_eq(reference_repaired.recovery.retained_bytes, 23912L)
    assert_eq(reference_repaired.downloaded_blocks, 1)
    assert_eq(requested, [2, 2, 1, 5, 4])
    assert_eq(full_gets, 1)
    assert_eq(@fs.read_file(output).binary(), data)
    println(
      "difference proof: lost local checkpoint + damaged file; ordinary adoption refused; pinned reference rebuilt 23912 valid bytes without content writes or requests; upstream WebDAV repaired exactly [16384,20480); full downloads remain 1",
    )
    let saved = @fs.read_file(output + ".mfl").binary()
    let (stopped, _) = @http.get(origin + "/stop")
    assert_eq(stopped.code, 200)
    serving.wait()
    server.close()
    assert_eq(reopened.receive(output).downloaded_blocks, 0)
    assert_eq(@fs.read_file(output + ".mfl").binary(), saved)
    println(
      "WebDAV extension verified: upstream upload/full download, trusted adoption, same-size corruption audit retaining 23912 bytes, encoded-response refusal, one-block repair, sparse two-block pause/reopen, verified export and stopped-origin zero-fetch reuse",
    )
  })
}
