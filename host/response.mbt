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
async fn fetch(spec : @ledger.ObjectSpec, lease : @ledger.Lease) -> Bytes {
  @async.with_timeout(30000, () => {
    let requested = lease.range
    let (response, client) = @http.get_stream(spec.resource, headers={
      "Range": "bytes=\{requested.start}-\{requested.end - 1L}",
      "If-Range": spec.etag,
      "Accept-Encoding": "identity",
    })
    defer client.close()
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
    bytes
  })
}
