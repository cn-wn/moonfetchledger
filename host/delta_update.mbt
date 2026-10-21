///|
// The first update workflow deliberately supports ASCII DNS/IPv4 HTTP(S) URLs,
// without userinfo, fragments or IPv6 authority. Never reflect URLs in errors.
fn validate_delta_url(url : String) -> Unit raise HostError {
  let offset = if url.has_prefix("https://") {
    8
  } else if url.has_prefix("http://") {
    7
  } else {
    raise InvalidInput("delta URLs require HTTP or HTTPS")
  }
  if url.length() > 8192 {
    raise InvalidInput("delta URL exceeds 8192 characters")
  }
  for c in url {
    if c.to_int() < 33 || c.to_int() > 126 || c == '@' || c == '#' || c == '\\' {
      raise InvalidInput(
        "delta URL requires ASCII without userinfo, fragments, controls or backslashes",
      )
    }
  }
  let authority = url[offset:].split("/").collect()[0]
  let parts = authority.split(":").collect()
  if parts.length() > 2 || parts[0].is_empty() || parts[0].length() > 253 {
    raise InvalidInput("delta URL requires a DNS/IPv4 authority")
  }
  for label in parts[0].split(".") {
    if label.is_empty() ||
      label.length() > 63 ||
      label.has_prefix("-") ||
      label.has_suffix("-") {
      raise InvalidInput("delta URL has an invalid host label")
    }
    for c in label {
      if !((c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '-') {
        raise InvalidInput("delta URL has an unsupported host")
      }
    }
  }
  if parts.length() == 2 {
    let port = number(parts[1]) catch {
      _ => raise InvalidInput("delta URL requires a canonical decimal port")
    }
    if port < 1L || port > 65535L {
      raise InvalidInput("delta URL port must be 1..65535")
    }
  }
}

///|
/// Fetch bounded public metadata without redirects, decoding or filesystem writes.
/// Authenticate exact bytes before schema parsing. This distributes hash-pinned
/// metadata; it does not obtain the pin's authority or implement release signatures.
pub async fn fetch_delta_reference(
  url : String,
  expected_sha256 : String,
  request_timeout_ms~ : Int32 = 30000,
) -> @ledger.DeltaReference {
  validate_delta_url(url)
  if expected_sha256.length() != 64 ||
    request_timeout_ms < 1 ||
    request_timeout_ms > 120000 {
    raise InvalidInput(
      "metadata requires a lowercase SHA-256 pin and timeout in 1..120000 ms",
    )
  }
  for c in expected_sha256 {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      raise InvalidInput("metadata pin must be lowercase SHA-256 hex")
    }
  }
  @async.with_timeout(request_timeout_ms, () => {
    let (response, client) = @http.get_stream(url, headers={
      "Accept-Encoding": "identity",
    })
    defer client.close()
    if response.code != 200 ||
      response.headers.get("Content-Encoding").unwrap_or("identity") !=
      "identity" ||
      response.headers.get("Content-Range") is Some(_) {
      raise InvalidResponse(
        "metadata requires an unencoded 200 response without Content-Range; redirects unsupported",
      )
    }
    let declared = match response.headers.get("Content-Length") {
      Some(text) => {
        let n = number(text[:]) catch {
          _ =>
            raise InvalidResponse(
              "metadata Content-Length must be canonical decimal",
            )
        }
        if n > 16000000L {
          raise InvalidResponse("metadata exceeds 16000000 bytes")
        }
        Some(n.to_int())
      }
      None => None
    }
    let buffer = Buffer()
    let mut size = 0
    while client.read_some(max_len=(16000001 - size).min(65536)) is Some(bytes) {
      size += bytes.length()
      if size > 16000000 {
        raise InvalidResponse(
          "metadata exceeds 16000000 bytes; retain local files",
        )
      }
      buffer.write_bytes(bytes)
    }
    if declared is Some(n) && n != size {
      raise InvalidResponse("metadata body length differs from Content-Length")
    }
    @ledger.DeltaReference::from_bytes(buffer.to_bytes(), expected_sha256)
  }) catch {
    InvalidResponse(_) as error => raise error
    @ledger.InvalidManifest(_) as error => raise error
    @ledger.InvalidCheckpoint(_) as error => raise error
    @async.TimeoutError =>
      raise InvalidResponse(
        "metadata request timed out; retain files and retry",
      )
    _ =>
      raise InvalidResponse(
        "metadata HTTP request failed; check URL/network and retry",
      )
  }
}

///|
pub struct DeltaUpdateReport {
  seed : SeedReuseReport?
  receive : DownloadReport
  exported : Bool
} derive(Debug)

///|
pub extend DeltaUpdateReport with Debug::{to_repr}

///|
/// Create a new update from one old seed, or explicitly resume an existing session
/// without consuming a seed. Deliver only after full verification. Preflight
/// rejects invalid controls and occupied delivery paths before seed/output writes.
/// Failures retain partial progress; retry with resuming=true and the same metadata.
pub async fn update_from_seed(
  reference : @ledger.DeltaReference,
  output : String,
  seed? : String,
  resuming~ : Bool = false,
  export_to? : String,
  parallel~ : Int32 = 4,
  stop_after_blocks? : Int32,
  max_attempts~ : Int32 = 1,
  request_timeout_ms~ : Int32 = 30000,
  auth? : BearerAuth,
) -> DeltaUpdateReport {
  validate_delta_url(reference.spec.resource)
  if output.is_empty() ||
    parallel < 1 ||
    parallel > 16 ||
    max_attempts < 1 ||
    max_attempts > 8 ||
    request_timeout_ms < 1 ||
    request_timeout_ms > 120000 ||
    (stop_after_blocks is Some(n) && n < 0) {
    raise InvalidInput(
      "update requires output, parallel 1..16, attempts 1..8, timeout 1..120000 ms and nonnegative block budget",
    )
  }
  if auth is Some(credential) {
    credential.check_resource(reference.spec.resource)
  }
  if resuming {
    if seed is Some(_) ||
      !@fs.exists(output) ||
      !@fs.exists(output + ".mfl") ||
      !@fs.exists(output + ".mfl.lock") {
      raise InvalidInput(
        "resume requires existing output/checkpoint/lock and forbids a seed; preserve partial progress",
      )
    }
  } else if seed is None {
    raise InvalidInput(
      "new delta update requires a seed; use resume explicitly for existing progress",
    )
  }
  if export_to is Some(destination) {
    let entry = canonical_entry(output)
    let reserved = [
      entry,
      entry + ".mfl",
      entry + ".mfl.lock",
      entry + ".mfl.next",
      entry + ".mfl.recovering",
    ]
    if destination.is_empty() ||
      @fs.exists(destination) ||
      @fs.exists(destination + ".next") ||
      reserved.contains(canonical_entry(destination)) ||
      reserved.contains(canonical_entry(destination + ".next")) {
      raise InvalidInput(
        "delivery requires a new path and temporary outside the staging session",
      )
    }
  }
  let staged = match seed {
    Some(path) => Some(reuse_from_seed(reference, path, output))
    None => None
  }
  let received = download(
    reference.spec,
    output,
    chunk_size=reference.chunk_size,
    parallel~,
    stop_after_blocks?,
    max_attempts~,
    request_timeout_ms~,
    auth?,
  )
  let exported = if received.complete && export_to is Some(destination) {
    export_verified(reference.spec, output, destination)
    true
  } else {
    false
  }
  { seed: staged, receive: received, exported, }
}
