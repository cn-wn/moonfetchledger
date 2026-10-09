///|
fn argument(values : Map[String, String], name : String) -> String raise {
  values.get(name).unwrap_or_else(() => fail("missing \{name}"))
}

///|
fn integer(text : String, name : String) -> Int64 raise {
  let value = @strconv.parse_int64(text) catch {
    _ => fail("\{name} must be a nonnegative decimal integer")
  }
  if value < 0L || value.to_string() != text {
    fail("\{name} must be a canonical nonnegative decimal integer")
  }
  value
}

///|
fn small(
  values : Map[String, String],
  name : String,
  default : Int,
) -> Int raise {
  let value = integer(values.get(name).unwrap_or(default.to_string()), name)
  if value > 2147483647L {
    fail("\{name} exceeds Int")
  }
  value.to_int()
}

///|
async fn run() -> Unit {
  let args = @env.args()
  let values : Map[String, String] = Map([])
  let mut auditing = false
  let mut adopting = false
  for i = 1; i < args.length(); {
    let flag = args[i]
    if flag == "--" {
      continue i + 1
    }
    if flag == "--help" {
      println(
        "fetch --url URL --output PATH --length N --etag QUOTED_ETAG --sha256 HEX [--chunk-size N] [--parallel 1..16] [--stop-after-blocks N] [--max-attempts 1..8] [--retry-delay-ms 0..30000] [--request-timeout-ms 1..120000]",
      )
      println(
        "Add --audit to inspect an existing session offline and emit MFLAUDIT1 JSON; download options are rejected in audit mode.",
      )
      println(
        "Add --adopt to verify an existing local file and create its recovery checkpoint; only --chunk-size is accepted in addition to identity options.",
      )
      return
    }
    if flag == "--audit" {
      if auditing {
        fail("duplicate option: --audit")
      }
      auditing = true
      continue i + 1
    }
    if flag == "--adopt" {
      if adopting {
        fail("duplicate option: --adopt")
      }
      adopting = true
      continue i + 1
    }
    if ![
        "--url", "--output", "--length", "--etag", "--sha256", "--chunk-size", "--parallel",
        "--stop-after-blocks", "--max-attempts", "--retry-delay-ms", "--request-timeout-ms",
      ].contains(flag) {
      fail("unknown option: \{flag}; use --help")
    }
    if i + 1 >= args.length() || values.contains(flag) {
      fail("missing value or duplicate option: \{flag}")
    }
    values[flag] = args[i + 1]
    continue i + 2
  }
  let spec = @ledger.ObjectSpec::new(
    argument(values, "--url"),
    integer(argument(values, "--length"), "--length"),
    argument(values, "--etag"),
    argument(values, "--sha256"),
  )
  if adopting {
    if auditing {
      fail("--adopt and --audit are mutually exclusive")
    }
    for key, _ in values {
      if ![
          "--url", "--output", "--length", "--etag", "--sha256", "--chunk-size",
        ].contains(key) {
        fail("download option \{key} is unsupported with --adopt")
      }
    }
    @host.adopt(
      spec,
      argument(values, "--output"),
      chunk_size=small(values, "--chunk-size", 65536),
    )
    println("adopted: confirmed=\{spec.length}")
    return
  }
  if auditing {
    for key, _ in values {
      if !["--url", "--output", "--length", "--etag", "--sha256"].contains(key) {
        fail("download option \{key} is unsupported with --audit")
      }
    }
    println(
      @host.audit(spec, argument(values, "--output")).to_json().stringify(),
    )
    return
  }
  let report = @host.download(
    spec,
    argument(values, "--output"),
    chunk_size=small(values, "--chunk-size", 65536),
    parallel=small(values, "--parallel", 4),
    stop_after_blocks=small(values, "--stop-after-blocks", 100000),
    max_attempts=small(values, "--max-attempts", 1),
    retry_delay_ms=small(values, "--retry-delay-ms", 200),
    request_timeout_ms=small(values, "--request-timeout-ms", 30000),
  )
  println(
    "\{if report.complete { "complete" } else { "paused" }}: confirmed=\{report.confirmed_bytes} fetched=\{report.downloaded_blocks} retained=\{report.recovery.retained_bytes} invalidated=\{report.recovery.invalidated.length()}",
  )
  for range in report.recovery.invalidated {
    println("refetched corrupted/missing block [\{range.start},\{range.end})")
  }
}

///|
async fn main {
  run() catch {
    error => fail("download failed: \{Repr(error)}")
  }
}
