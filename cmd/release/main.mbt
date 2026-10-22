///|
fn required(values : Map[String, String], key : String) -> String raise {
  values.get(key).unwrap_or_else(() => fail("missing \{key}; see --help"))
}

///|
fn integer(text : String) -> Int64 raise {
  let n = @strconv.parse_int64(text)
  if n < 0L || n.to_string() != text {
    fail("numbers must be canonical nonnegative Int64 decimal")
  }
  n
}

///|
fn small(
  values : Map[String, String],
  key : String,
  fallback : Int32,
) -> Int32 raise {
  let n = integer(values.get(key).unwrap_or(fallback.to_string()))
  if n > 2147483647L {
    fail("numeric option exceeds Int32")
  }
  n.to_int()
}

///|
fn now() -> Int64 raise {
  let seconds = @env.now() / 1000UL
  if seconds > 9223372036854775807UL {
    fail("system clock exceeds Int64 Unix seconds")
  }
  seconds.reinterpret_as_int64()
}

///|
fn report(phase : String, fields : Array[String]) -> Unit {
  let row = [Json::string("MFLSIGNED1"), Json::string(phase)]
  for field in fields {
    row.push(Json::string(field))
  }
  println(Json::array(row).stringify())
}

///|
fn artifact_auth(
  values : Map[String, String],
  allow_loopback : Bool,
) -> @host.BearerAuth? raise {
  if values.contains("--bearer-env") != values.contains("--artifact-url") {
    fail(
      "--bearer-env and --artifact-url must be supplied together to bind the credential destination",
    )
  }
  match values.get("--bearer-env") {
    None => None
    Some(name) => {
      if name.is_empty() || name.length() > 128 {
        fail("Bearer variable name must be an ASCII environment identifier")
      }
      let mut first = true
      for c in name {
        if !((c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          c == '_' ||
          (!first && c >= '0' && c <= '9')) {
          fail("Bearer variable name must be an ASCII environment identifier")
        }
        first = false
      }
      let token = @env.get_env_var(name).unwrap_or_else(() => {
        fail("Bearer environment variable is unset")
      })
      Some(
        @host.BearerAuth::new(
          required(values, "--artifact-url"),
          token,
          allow_loopback_http=allow_loopback,
        ),
      )
    }
  }
}

///|
async fn run() -> Unit {
  let args = @env.args()
  let values : Map[String, String] = Map([])
  let mut mode = "update"
  let mut resuming = false
  let mut loopback_auth = false
  for i = 1; i < args.length(); {
    let flag = args[i]
    if flag == "--" {
      continue i + 1
    }
    if flag == "--help" {
      println(
        "release --sign --private-seed-file RAW32 --descriptor NEW_FILE --product ID --channel ID --version N --issued-at UNIX --expires-at UNIX --metadata-url URL --metadata-sha256 HEX",
      )
      println(
        "release (--init-state | --recover-state) --public-key-file RAW32 --product ID --channel ID --state FILE [--minimum-version N]",
      )
      println(
        "release (--release FILE | --release-url URL) --public-key-file RAW32 --product ID --channel ID --state FILE (--seed OLD | --resume) --output STAGING [--metadata LOCAL_DELTA] [--export-to NEW_READY] [--minimum-version N] [--parallel 1..16] [--stop-after-blocks N] [--max-attempts 1..8] [--request-timeout-ms 1..120000]",
      )
      println(
        "Public keys require independent provisioning. Uses the system Unix clock; there is no clock override. Protect state and .lock/.next; never reset to bypass rollback errors. No key rotation or installed-file replacement.",
      )
      println(
        "Private artifacts: --bearer-env NAME --artifact-url EXACT_EXPECTED_URL; credentials are never sent to announcement/metadata URLs. --allow-loopback-auth is only for explicit 127.0.0.1 HTTP tests.",
      )
      return
    }
    if ["--sign", "--init-state", "--recover-state"].contains(flag) {
      if mode != "update" {
        fail("choose only one command mode")
      }
      mode = flag
      continue i + 1
    }
    if flag == "--resume" {
      if resuming {
        fail("duplicate --resume")
      }
      resuming = true
      continue i + 1
    }
    if flag == "--allow-loopback-auth" {
      if loopback_auth {
        fail("duplicate --allow-loopback-auth")
      }
      loopback_auth = true
      continue i + 1
    }
    if ![
        "--private-seed-file", "--descriptor", "--product", "--channel", "--version",
        "--issued-at", "--expires-at", "--metadata-url", "--metadata-sha256", "--public-key-file",
        "--state", "--minimum-version", "--release", "--release-url", "--seed", "--output",
        "--metadata", "--export-to", "--parallel", "--stop-after-blocks", "--max-attempts",
        "--request-timeout-ms", "--bearer-env", "--artifact-url",
      ].contains(flag) ||
      i + 1 >= args.length() ||
      values.contains(flag) {
      fail("unknown, duplicate or missing-value option: \{flag}")
    }
    values[flag] = args[i + 1]
    continue i + 2
  }
  let allowed = if mode == "--sign" {
    [
      "--private-seed-file", "--descriptor", "--product", "--channel", "--version",
      "--issued-at", "--expires-at", "--metadata-url", "--metadata-sha256",
    ]
  } else if mode == "--init-state" || mode == "--recover-state" {
    [
      "--public-key-file", "--product", "--channel", "--state", "--minimum-version",
    ]
  } else {
    [
      "--public-key-file", "--product", "--channel", "--state", "--minimum-version",
      "--release", "--release-url", "--seed", "--output", "--metadata", "--export-to",
      "--parallel", "--stop-after-blocks", "--max-attempts", "--request-timeout-ms",
      "--bearer-env", "--artifact-url",
    ]
  }
  for key in values.keys() {
    if !allowed.contains(key) {
      fail("unsupported option for command mode: \{key}")
    }
  }
  if resuming && mode != "update" {
    fail("--resume is only valid for updates")
  }
  if loopback_auth && (mode != "update" || !values.contains("--bearer-env")) {
    fail("--allow-loopback-auth requires an update with --bearer-env")
  }
  let auth = if mode == "update" {
    artifact_auth(values, loopback_auth)
  } else {
    None
  }
  let product = required(values, "--product")
  let channel = required(values, "--channel")
  if mode == "--sign" {
    let descriptor = @signed.Release::new(
      product,
      channel,
      integer(required(values, "--version")),
      integer(required(values, "--issued-at")),
      integer(required(values, "--expires-at")),
      required(values, "--metadata-url"),
      required(values, "--metadata-sha256"),
    )
    @host.write_signed_release(
      descriptor,
      required(values, "--private-seed-file"),
      required(values, "--descriptor"),
    )
    report("signed", [descriptor.version.to_string()])
    return
  }
  // CLI shape/control validation precedes key loading, network or state writes.
  let timeout = small(values, "--request-timeout-ms", 30000)
  let parallel = small(values, "--parallel", 4)
  let attempts = small(values, "--max-attempts", 1)
  let budget = if values.contains("--stop-after-blocks") {
    Some(small(values, "--stop-after-blocks", 0))
  } else {
    None
  }
  if timeout < 1 ||
    timeout > 120000 ||
    parallel < 1 ||
    parallel > 16 ||
    attempts < 1 ||
    attempts > 8 {
    fail("invalid parallel/attempt/timeout limits")
  }
  if mode == "update" &&
    (
      values.contains("--release") == values.contains("--release-url") ||
      resuming == values.contains("--seed")
    ) {
    fail("choose exactly release or release-url, and seed or resume")
  }
  let state = required(values, "--state")
  let output = if mode == "update" { required(values, "--output") } else { "" }
  let trust = @host.load_release_trust(
    required(values, "--public-key-file"),
    product,
    channel,
    minimum_version=integer(values.get("--minimum-version").unwrap_or("1")),
  )
  if mode == "--init-state" {
    @host.initialize_release_state(state, trust)
    report("initialized", [trust.key_sha256])
    return
  }
  if mode == "--recover-state" {
    @host.recover_release_state(state, trust)
    report("state-recovered", [trust.key_sha256])
    return
  }
  let bytes = match values.get("--release") {
    Some(path) => @host.load_release(path)
    None =>
      @host.fetch_release(
        required(values, "--release-url"),
        request_timeout_ms=timeout,
      )
  }
  let result = @host.update_signed_release(
    bytes,
    trust,
    state,
    output,
    now=now(),
    metadata_file?=values.get("--metadata"),
    seed?=values.get("--seed"),
    resuming~,
    export_to?=values.get("--export-to"),
    parallel~,
    stop_after_blocks?=budget,
    max_attempts=attempts,
    request_timeout_ms=timeout,
    auth?,
  )
  report(if result.update.receive.complete { "complete" } else { "paused" }, [
    result.version.to_string(),
    result.update.receive.confirmed_bytes.to_string(),
    result.update.receive.downloaded_blocks.to_string(),
    result.payload_sha256,
  ])
  if result.update.exported {
    report("exported", [result.version.to_string()])
  }
}

///|
async fn main {
  run() catch {
    error =>
      fail(
        "signed release operation failed; retain state/staging and correct the cause: \{Repr(error)}",
      )
  }
}
