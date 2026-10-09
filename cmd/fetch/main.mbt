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
  let mut progress = false
  let mut loopback_auth = false
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
      println(
        "Add --export-to NEW_PATH to copy a complete verified session to a new file; source and sidecars are retained, download options are rejected.",
      )
      println(
        "Add --repair-from BACKUP to repair an existing session offline using a fully verified local file; download options are rejected.",
      )
      println(
        "Add --progress to emit MFLPROGRESS1 JSON lines during downloads, followed by the normal summary.",
      )
      println(
        "Add --bearer-env NAME to read a transient Bearer token from an environment variable; HTTPS required. --allow-loopback-auth permits only 127.0.0.1 HTTP for local testing.",
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
    if flag == "--progress" {
      if progress {
        fail("duplicate option: --progress")
      }
      progress = true
      continue i + 1
    }
    if flag == "--allow-loopback-auth" {
      if loopback_auth {
        fail("duplicate option: --allow-loopback-auth")
      }
      loopback_auth = true
      continue i + 1
    }
    if ![
        "--url", "--output", "--length", "--etag", "--sha256", "--chunk-size", "--parallel",
        "--stop-after-blocks", "--max-attempts", "--retry-delay-ms", "--request-timeout-ms",
        "--export-to", "--repair-from", "--bearer-env",
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
  if loopback_auth &&
    (
      !values.contains("--bearer-env") ||
      auditing ||
      adopting ||
      values.contains("--export-to") ||
      values.contains("--repair-from")
    ) {
    fail("--allow-loopback-auth requires --bearer-env in download mode")
  }
  if progress &&
    (
      auditing ||
      adopting ||
      values.contains("--export-to") ||
      values.contains("--repair-from")
    ) {
    fail("--progress is supported only for downloads")
  }
  if values.get("--repair-from") is Some(backup) {
    if auditing || adopting || values.contains("--export-to") {
      fail(
        "--repair-from, --export-to, --adopt and --audit are mutually exclusive",
      )
    }
    for key, _ in values {
      if ![
          "--url", "--output", "--length", "--etag", "--sha256", "--repair-from",
        ].contains(key) {
        fail("download option \{key} is unsupported with --repair-from")
      }
    }
    let report = @host.repair_from_local(
      spec,
      argument(values, "--output"),
      backup,
    )
    println(
      "repaired: confirmed=\{report.confirmed_bytes} copied=\{report.repaired_blocks} retained=\{report.recovery.retained_bytes} invalidated=\{report.recovery.invalidated.length()}",
    )
    return
  }
  if values.get("--export-to") is Some(destination) {
    if auditing || adopting {
      fail("--export-to, --adopt and --audit are mutually exclusive")
    }
    for key, _ in values {
      if !["--url", "--output", "--length", "--etag", "--sha256", "--export-to"].contains(
          key,
        ) {
        fail("download option \{key} is unsupported with --export-to")
      }
    }
    @host.export_verified(spec, argument(values, "--output"), destination)
    println("exported: bytes=\{spec.length}")
    return
  }
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
  let auth = match values.get("--bearer-env") {
    None => None
    Some(name) => {
      if name.is_empty() || name.length() > 128 {
        fail("--bearer-env requires an environment variable identifier")
      }
      for i, c in name {
        if !((c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          c == '_' ||
          (i > 0 && c >= '0' && c <= '9')) {
          fail("--bearer-env requires an environment variable identifier")
        }
      }
      let token = @env.get_env_var(name).unwrap_or_else(() => {
        fail("Bearer environment variable is unset")
      })
      Some(
        @host.BearerAuth::new(
          spec.resource,
          token,
          allow_loopback_http=loopback_auth,
        ),
      )
    }
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
    on_progress=event => if progress { println(event.to_json().stringify()) },
    auth?,
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
