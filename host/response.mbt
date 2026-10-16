///|
/// This adapter accepts a single canonical bytes Content-Range only.
/// It deliberately does not expose a general HTTP Range parser.
fn number(text : StringView) -> Int64 raise {
  if text.is_empty() ||
    text.length() > 19 ||
    (text.length() > 1 && text[0] == '0') {
    raise InvalidResponse("noncanonical Content-Range integer")
  }
  for c in text {
    if c < '0' || c > '9' {
      raise InvalidResponse("invalid Content-Range integer")
    }
  }
  @strconv.parse_int64(text) catch {
    _ => raise InvalidResponse("Content-Range integer exceeds Int64")
  }
}

///|
fn content_range(text : String) -> (@ledger.ByteRange, Int64) raise {
  if !text.has_prefix("bytes ") {
    raise InvalidResponse("expected a single bytes Content-Range")
  }
  let parts = text[6:].split("/").collect()
  if parts.length() != 2 {
    raise InvalidResponse("missing or extra Content-Range length")
  }
  let bounds = parts[0].split("-").collect()
  if bounds.length() != 2 {
    raise InvalidResponse("missing or extra Content-Range bounds")
  }
  let start = number(bounds[0])
  let last = number(bounds[1])
  let total = number(parts[1])
  if start > last || last >= total {
    raise InvalidResponse("Content-Range bounds exceed object")
  }
  ({ start, end: last + 1L, }, total)
}

///|
priv enum FetchResult {
  Payload(Bytes)
  Retry(String, Int32)
}

///|
fn retry_delay(header : String?, fallback : Int32) -> Int32 raise HostError {
  match header {
    None => fallback
    Some(text) => {
      if text.is_empty() || text.length() > 8 {
        raise InvalidResponse(
          "Retry-After requires decimal seconds in 0..30; HTTP-date unsupported",
        )
      }
      let mut seconds = 0
      for c in text {
        if c < '0' || c > '9' {
          raise InvalidResponse(
            "Retry-After requires decimal seconds; HTTP-date unsupported",
          )
        }
        seconds = seconds * 10 + c.to_int() - '0'.to_int()
        if seconds > 30 {
          raise InvalidResponse(
            "Retry-After exceeds the 30 second wait limit; restart later",
          )
        }
      }
      fallback.max(seconds * 1000)
    }
  }
}

///|
async fn fetch_once(
  spec : @ledger.ObjectSpec,
  requested : @ledger.ByteRange,
  timeout : Int32,
  delay : Int32,
  auth : BearerAuth?,
) -> FetchResult {
  @async.with_timeout(timeout, () => {
    let headers : @http.Headers = {
      "Range": "bytes=\{requested.start}-\{requested.end - 1L}",
      "If-Range": spec.etag,
      "Accept-Encoding": "identity",
    }
    if auth is Some(credential) {
      credential.check_resource(spec.resource)
      headers["Authorization"] = "Bearer " + credential.token
    }
    let (response, client) = @http.get_stream(spec.resource, headers~)
    defer client.close()
    if auth is Some(_) && (response.code == 401 || response.code == 403) {
      raise InvalidResponse(
        "HTTP \{response.code}: authentication refused; obtain a fresh credential and resume the retained session",
      )
    }
    if response.code == 429 || response.code == 503 {
      return Retry(
        "HTTP \{response.code}",
        retry_delay(response.headers.get("Retry-After"), delay),
      )
    }
    if response.code != 206 {
      raise InvalidResponse(
        "expected 206, got \{response.code}; retain files and restart explicitly",
      )
    }
    let etag = response.headers.get("ETag").unwrap_or("")
    let encoding = response.headers
      .get("Content-Encoding")
      .unwrap_or("identity")
    let (range, total) = content_range(
      response.headers.get("Content-Range").unwrap_or(""),
    )
    if etag != spec.etag ||
      total != spec.length ||
      range != requested ||
      encoding != "identity" {
      raise InvalidResponse(
        "ETag, range, length or encoding differs from the requested object",
      )
    }
    let bytes = client.read_exactly(requested.length().to_int())
    if client.read_some(max_len=1) is Some(_) {
      raise InvalidResponse("response body contains extra bytes")
    }
    Payload(bytes)
  }) catch {
    @async.TimeoutError => Retry("request timeout", delay)
    InvalidResponse(_) as error => raise error
    InvalidInput(_) as error => raise error
    other => {
      if auth is Some(_) {
        // Do not expose untrusted parser/transport diagnostics that could reflect
        // a credential. Known adapter diagnostics above contain no input values.
        raise InvalidResponse(
          "authenticated HTTP I/O failed; check TLS/network and resume with valid credentials",
        )
      }
      raise other
    }
  }
}

///|
// Only requests are retried. Storage writes and ledger commits happen once,
// outside this loop, after the response has passed every representation check.
async fn fetch(
  spec : @ledger.ObjectSpec,
  range : @ledger.ByteRange,
  attempts : Int32,
  delay : Int32,
  timeout : Int32,
  auth : BearerAuth?,
) -> Bytes {
  for attempt = 1; ; attempt = attempt + 1 {
    match fetch_once(spec, range, timeout, delay, auth) {
      Payload(bytes) => return bytes
      Retry(reason, wait) => {
        if attempt == attempts {
          raise RetryExhausted(range, attempt, reason)
        }
        @async.sleep(wait)
      }
    }
  }
}
