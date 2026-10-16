///|
// get_file does not expose Content-Encoding and buffers its response. The
// upstream's open Transport hook lets us validate metadata and bound consumption
// before it buffers. HTTP framing/TLS and WebDAV requests remain upstream work.
priv struct GuardTransport {
  inner : &@transport.Transport
  spec : @ledger.ObjectSpec
}

///|
impl @transport.Transport for GuardTransport with fn send(self, request) {
  if request.url != self.spec.resource ||
    request.http_method != Get ||
    request.headers.get("If-Match") != Some(self.spec.etag) {
    raise @transport.TransportError::Malformed(
      "WebDAV request does not match bound object",
    )
  }
  let header = request.headers.get("Range").unwrap_or("")
  if !header.has_prefix("bytes=") {
    raise @transport.TransportError::Malformed(
      "WebDAV requires one explicit bounded range",
    )
  }
  let bounds = header[6:].split("-").collect()
  if bounds.length() != 2 {
    raise @transport.TransportError::Malformed(
      "WebDAV requires one explicit bounded range",
    )
  }
  let first = @strconv.parse_int64(bounds[0]) catch {
    _ =>
      raise @transport.TransportError::Malformed(
        "WebDAV range start is invalid",
      )
  }
  let last = @strconv.parse_int64(bounds[1]) catch {
    _ =>
      raise @transport.TransportError::Malformed("WebDAV range end is invalid")
  }
  if first < 0L ||
    last < first ||
    last >= self.spec.length ||
    last - first >= 4194304L {
    raise @transport.TransportError::Malformed(
      "WebDAV requested range exceeds object/block bounds",
    )
  }
  let length = (last - first + 1L).to_int()
  let raw = self.inner.send({
    ..request,
    headers: request.headers.set("Accept-Encoding", "identity"),
  })
  defer raw.body.close()
  if raw.status != 206 {
    raise @transport.TransportError::Malformed(
      "WebDAV requires 206; redirects and 200 fallback are refused",
    )
  }
  if raw.headers.get("ETag") != Some(self.spec.etag) ||
    raw.headers.get("Content-Range") !=
    Some("bytes \{first}-\{last}/\{self.spec.length}") {
    raise @transport.TransportError::Malformed(
      "WebDAV response identity/range differs from trusted object",
    )
  }
  if raw.headers.get("Content-Encoding").unwrap_or("identity") != "identity" ||
    raw.headers
    .get("Content-Type")
    .unwrap_or("")
    .trim()
    .to_lower()
    .has_prefix("multipart/") {
    raise @transport.TransportError::Malformed(
      "WebDAV encoded/multipart representations are unsupported",
    )
  }
  if raw.headers.get("Content-Length") is Some(value) &&
    value != length.to_string() {
    raise @transport.TransportError::Malformed(
      "WebDAV response Content-Length differs from requested block",
    )
  }
  let buffer = @buffer.Buffer(size_hint=length)
  while raw.body.read_some(max_len=length - buffer.length() + 1) is Some(bytes) {
    if bytes.length() > length - buffer.length() {
      raise @transport.TransportError::Malformed(
        "WebDAV response contains extra bytes",
      )
    }
    buffer.write_bytes(bytes)
  }
  if buffer.length() != length {
    raise @transport.TransportError::Malformed("WebDAV response is truncated")
  }
  { ..raw, body: @transport.ResponseBody::from_bytes(buffer.to_bytes()), }
}
