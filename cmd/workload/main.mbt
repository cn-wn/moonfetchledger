///|
fn number(text : String) -> Int32 raise {
  let value = @strconv.parse_int(text)
  if value.to_string() != text {
    fail("canonical integer required")
  }
  value
}

///|
fn elapsed(start : UInt64) -> String raise {
  let end = @env.now()
  if end < start {
    fail("system clock moved backward during measurement")
  }
  (end - start).to_string()
}

///|
async fn rss() -> Json {
  if !@fs.exists("/proc/self/status") {
    return Json::null()
  }
  for line in @fs.read_file("/proc/self/status").text().split("\n") {
    if line.has_prefix("VmHWM:") {
      let fields = line.split(" ").filter(p => !p.is_empty()).collect()
      if fields.length() == 3 && fields[2] == "kB" {
        return Json::string(@strconv.parse_int64(fields[1].trim()).to_string())
      }
    }
  }
  Json::null()
}

///|
async fn matrix(
  scenario : String,
  mib : Int32,
  chunk : Int32,
  delay : Int32,
  dir : String,
) -> Unit {
  let whole_start = @env.now()
  @fs.mkdir(dir) // Refuse existing directories before installing cleanup.
  defer @fs.rmdir(dir, recursive=true)
  let fixture = generate(dir, scenario, mib.to_int64() * 1048576L + 17L, chunk)
  let target = @fs.open(dir + "/target", mode=ReadOnly)
  defer target.close()
  let mut requests = 0L
  let mut payload = 0L
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
        group.spawn_bg(() => {
          defer conn.close()
          assert_eq(request.path, "/target")
          assert_eq(request.headers.get("If-Range"), Some("\"workload-v1\""))
          let bounds = request.headers.get("Range").unwrap()[6:]
            .split("-")
            .collect()
          let start = @strconv.parse_int64(bounds[0])
          let end = @strconv.parse_int64(bounds[1]) + 1L
          assert_true(start >= 0L && end > start && end <= fixture.length)
          assert_true(end - start <= chunk.to_int64())
          if delay > 0 {
            @async.sleep(delay)
          }
          let bytes = target.read_exactly_at(
            (end - start).to_int(),
            position=start,
          )
          conn.send_response(206, "Partial Content", extra_headers={
            "Content-Length": bytes.length().to_string(),
            "Content-Range": "bytes \{start}-\{end-1}/\{fixture.length}",
            "ETag": "\"workload-v1\"",
            "Connection": "close",
          })
          conn.write(bytes)
          conn.end_response()
          requests += 1L
          payload += bytes.length().to_int64()
        })
      }
    })
    let spec = @ledger.ObjectSpec::new(
      base + "/target",
      fixture.length,
      "\"workload-v1\"",
      fixture.sha256,
    )
    let pin = @host.write_delta_reference(
      spec,
      dir + "/target",
      dir + "/delta",
      chunk_size=chunk,
    )
    let reference = @host.load_delta_reference(dir + "/delta", pin)
    let setup_ms = elapsed(whole_start)
    let start = @env.now()
    let plan = @host.preview_seed(
      reference,
      dir + "/seed",
      max_scan_bytes=fixture.seed_bytes,
      max_hash_bytes=fixture.length * 8L,
    )
    let preview_ms = elapsed(start)
    assert_eq(plan.reused_bytes, fixture.expected_reused)
    assert_eq(plan.download_bytes(), fixture.length - fixture.expected_reused)
    let update_start = @env.now()
    let result = @host.update_from_seed(
      reference,
      dir + "/staging",
      seed=dir + "/seed",
      export_to=dir + "/ready",
      parallel=4,
      max_scan_bytes=fixture.seed_bytes,
      max_hash_bytes=fixture.length * 8L,
    )
    let update_ms = elapsed(update_start)
    assert_true(result.receive.complete && result.exported)
    assert_eq(result.seed.unwrap().reused_bytes, plan.reused_bytes)
    assert_eq(payload, plan.download_bytes())
    assert_eq(requests, result.receive.downloaded_blocks.to_int64())
    assert_eq(file_hash(dir + "/ready"), fixture.sha256)
    assert_eq(file_hash(dir + "/target"), fixture.sha256)
    assert_eq(file_hash(dir + "/seed"), fixture.seed_sha256)
    ignore(@http.get(base + "/stop"))
    serving.wait()
    println(
      Json::array([
        Json::string("MFLSTRESS1"),
        Json::string(scenario),
        Json::string(fixture.length.to_string()),
        Json::string(chunk.to_string()),
        Json::string(delay.to_string()),
        Json::string(fixture.seed_bytes.to_string()),
        Json::string(plan.reused_bytes.to_string()),
        Json::string(plan.download_bytes().to_string()),
        Json::string(plan.hashed_bytes.to_string()),
        Json::string(requests.to_string()),
        Json::string(payload.to_string()),
        Json::string(setup_ms),
        Json::string(preview_ms),
        Json::string(update_ms),
        Json::string(elapsed(whole_start)),
        rss(),
      ]).stringify(),
    )
  })
}

///|
async fn main {
  let args = @env.args()
  if args.length() != 7 || args[1] != "matrix" {
    fail("workload matrix CASE MIB CHUNK_KIB DELAY_MS NEW_DIRECTORY")
  }
  let scenario = args[2]
  let mib = number(args[3])
  let kib = number(args[4])
  let delay = number(args[5])
  if ![
      "baseline", "identical", "shifted", "sparse", "insert-delete", "reordered",
      "low-reuse",
    ].contains(scenario) ||
    mib < 1 ||
    mib > 1024 ||
    kib < 1 ||
    kib > 4096 ||
    delay < 0 ||
    delay > 1000 {
    fail(
      "supported case required; size 1..1024 MiB, chunk 1..4096 KiB, delay 0..1000 ms",
    )
  }
  matrix(scenario, mib, kib * 1024, delay, args[6])
}
