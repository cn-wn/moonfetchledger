///|
fn required(values : Map[String, String], name : String) -> String raise {
  values.get(name).unwrap_or_else(() => fail("missing \{name}"))
}

///|
fn integer(text : String, name : String) -> Int64 raise {
  let n = @strconv.parse_int64(text) catch {
    _ => fail("\{name} requires canonical nonnegative decimal")
  }
  if n < 0L || n.to_string() != text {
    fail("\{name} requires canonical nonnegative decimal")
  }
  n
}

///|
fn small(
  values : Map[String, String],
  name : String,
  fallback : Int32,
) -> Int32 raise {
  let n = integer(values.get(name).unwrap_or(fallback.to_string()), name)
  if n > 2147483647L {
    fail("\{name} exceeds Int32")
  }
  n.to_int()
}

///|
async fn run() -> Unit {
  let args = @env.args()
  let values : Map[String, String] = Map([])
  let seeds : Array[String] = []
  let mut publishing = false
  let mut previewing = false
  let mut resuming = false
  for i = 1; i < args.length(); {
    let flag = args[i]
    if flag == "--" {
      continue i + 1
    }
    if flag == "--help" {
      println(
        "--checkpoint-blocks 1..1024 batches synced checkpoints; default 1. A pending batch can be repeated after failure.",
      )
      println(
        "update --publish --source FILE --metadata NEW_FILE --url URL --length N --etag QUOTED_ETAG --sha256 TRUSTED_HEX [--chunk-size N]",
      )
      println(
        "update (--metadata FILE | --metadata-url URL) --metadata-sha256 TRUSTED_PIN --seed OLD_FILE --output NEW_STAGING [--export-to NEW_READY] [--parallel 1..16] [--stop-after-blocks N] [--max-attempts 1..8] [--request-timeout-ms 1..120000]",
      )
      println(
        "Use --preview with metadata/pin and --seed only for a read-only report. Repeat --seed for up to 32 ordered files (MFLPOOL1). Resume updates with --resume and no seeds. Pins require independent trust; cmd/release provides signed updates. Installed-file replacement is not implemented.",
      )
      println(
        "Initial scans accept --max-scan-bytes N and --max-hash-bytes N. These bound seed input and candidate SHA work, not network billing. Omit scan limits on resume.",
      )
      return
    }
    if flag == "--publish" {
      if publishing {
        fail("duplicate --publish")
      }
      publishing = true
      continue i + 1
    }
    if flag == "--preview" {
      if previewing {
        fail("duplicate --preview")
      }
      previewing = true
      continue i + 1
    }
    if flag == "--resume" {
      if resuming {
        fail("duplicate --resume")
      }
      resuming = true
      continue i + 1
    }
    if flag == "--seed" && i + 1 < args.length() {
      if seeds.length() >= 32 {
        fail("at most 32 seeds are supported")
      }
      seeds.push(args[i + 1])
      values[flag] = args[i + 1]
      continue i + 2
    }
    if ![
        "--source", "--metadata", "--metadata-url", "--metadata-sha256", "--url",
        "--length", "--etag", "--sha256", "--chunk-size", "--seed", "--output", "--export-to",
        "--parallel", "--stop-after-blocks", "--max-attempts", "--request-timeout-ms",
        "--max-scan-bytes", "--max-hash-bytes", "--checkpoint-blocks",
      ].contains(flag) ||
      i + 1 >= args.length() ||
      values.contains(flag) {
      fail("unknown, duplicate or missing-value option: \{flag}")
    }
    values[flag] = args[i + 1]
    continue i + 2
  }
  if publishing {
    if resuming || previewing {
      fail("--publish and --resume are exclusive")
    }
    for name in values.keys() {
      if ![
          "--source", "--metadata", "--url", "--length", "--etag", "--sha256", "--chunk-size",
        ].contains(name) {
        fail("unsupported publish option: \{name}")
      }
    }
    let spec = @ledger.ObjectSpec::new(
      required(values, "--url"),
      integer(required(values, "--length"), "--length"),
      required(values, "--etag"),
      required(values, "--sha256"),
    )
    let pin = @host.write_delta_reference(
      spec,
      required(values, "--source"),
      required(values, "--metadata"),
      chunk_size=small(values, "--chunk-size", 65536),
    )
    println(
      Json::array([
        Json::string("MFLUPDATE1"),
        Json::string("published"),
        Json::string(pin),
      ]).stringify(),
    )
    return
  }
  for
    name in [
      "--source", "--url", "--length", "--etag", "--sha256", "--chunk-size",
    ] {
    if values.contains(name) {
      fail("unsupported consumer option: \{name}")
    }
  }
  if values.contains("--metadata") == values.contains("--metadata-url") {
    fail("choose exactly one of --metadata and --metadata-url")
  }
  if previewing {
    if resuming {
      fail("preview cannot resume or write an update")
    }
    for name in values.keys() {
      if ![
          "--metadata", "--metadata-url", "--metadata-sha256", "--seed", "--request-timeout-ms",
          "--max-scan-bytes", "--max-hash-bytes",
        ].contains(name) {
        fail("unsupported preview option: \{name}")
      }
    }
  }
  if resuming == values.contains("--seed") {
    fail("choose exactly one of --seed and --resume")
  }
  let output = if previewing { "" } else { required(values, "--output") }
  let pin = required(values, "--metadata-sha256")
  let max_scan_bytes = values
    .get("--max-scan-bytes")
    .map(n => integer(n, "--max-scan-bytes"))
  let max_hash_bytes = values
    .get("--max-hash-bytes")
    .map(n => integer(n, "--max-hash-bytes"))
  if resuming && (max_scan_bytes is Some(_) || max_hash_bytes is Some(_)) {
    fail("scan limits are only for initial seed scans; omit them on resume")
  }
  let timeout = small(values, "--request-timeout-ms", 30000)
  let checkpoint_blocks = small(values, "--checkpoint-blocks", 1)
  if checkpoint_blocks < 1 || checkpoint_blocks > 1024 {
    fail("--checkpoint-blocks must be 1..1024")
  }
  let parallel = small(values, "--parallel", 4)
  let attempts = small(values, "--max-attempts", 1)
  let budget = values
    .get("--stop-after-blocks")
    .map(text => {
      let n = integer(text, "--stop-after-blocks")
      if n > 2147483647L {
        fail("block budget exceeds Int32")
      }
      n.to_int()
    })
  if parallel < 1 ||
    parallel > 16 ||
    attempts < 1 ||
    attempts > 8 ||
    timeout < 1 ||
    timeout > 120000 {
    fail("invalid parallel/attempt/timeout limits; see --help")
  }
  let reference = match values.get("--metadata") {
    Some(path) => @host.load_delta_reference(path, pin)
    None =>
      @host.fetch_delta_reference(
        required(values, "--metadata-url"),
        pin,
        request_timeout_ms=timeout,
      )
  }
  if previewing {
    println(
      if seeds.length() == 1 {
        @host.preview_seed(
          reference,
          seeds[0],
          max_scan_bytes?,
          max_hash_bytes?,
        )
        .to_json()
        .stringify()
      } else {
        @host.preview_seeds(reference, seeds, max_scan_bytes?, max_hash_bytes?)
        .to_json()
        .stringify()
      },
    )
    return
  }
  let report = if seeds.length() > 1 {
    @host.update_from_seeds(
      reference,
      seeds,
      output,
      export_to?=values.get("--export-to"),
      parallel~,
      stop_after_blocks?=budget,
      max_attempts=attempts,
      request_timeout_ms=timeout,
      max_scan_bytes?,
      max_hash_bytes?,
      checkpoint_blocks~,
    )
  } else {
    @host.update_from_seed(
      reference,
      output,
      seed?=values.get("--seed"),
      resuming~,
      export_to?=values.get("--export-to"),
      parallel~,
      stop_after_blocks?=budget,
      max_attempts=attempts,
      request_timeout_ms=timeout,
      max_scan_bytes?,
      max_hash_bytes?,
      checkpoint_blocks~,
    )
  }
  if report.seed is Some(seed) {
    println(
      Json::array([
        Json::string("MFLUPDATE1"),
        Json::string("seeded"),
        Json::string(seed.scanned_bytes.to_string()),
        Json::string(seed.reused_bytes.to_string()),
        Json::string(seed.reused_blocks.to_string()),
      ]).stringify(),
    )
  }
  println(
    Json::array([
      Json::string("MFLUPDATE1"),
      Json::string(if report.receive.complete { "complete" } else { "paused" }),
      Json::string(report.receive.confirmed_bytes.to_string()),
      Json::string(report.receive.downloaded_blocks.to_string()),
      Json::string(report.receive.recovery.retained_bytes.to_string()),
    ]).stringify(),
  )
  if report.exported {
    println(
      Json::array([
        Json::string("MFLUPDATE1"),
        Json::string("exported"),
        Json::string(reference.spec.sha256),
      ]).stringify(),
    )
  }
}

///|
async fn main {
  run() catch {
    error =>
      fail(
        "update failed; retain staging/checkpoint and use --resume after correction: \{Repr(error)}",
      )
  }
}
