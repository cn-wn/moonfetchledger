///|
/// Strict positional JSON array. No object keys can be silently overwritten.
/// Decimal strings avoid JS's floating-point integer precision limit.
pub fn Session::checkpoint(self : Session) -> String raise LedgerError {
  if self.recovering {
    raise RecoveryRequired
  }
  let records : Array[Json] = []
  for i, block in self.blocks {
    if block is Confirmed(_, hash) {
      records.push(
        Json::array([Json::string(i.to_string()), Json::string(hash)]),
      )
    }
  }
  Json::array([
    Json::string("MFL1"),
    Json::string(self.spec.resource),
    Json::string(self.spec.length.to_string()),
    Json::string(self.spec.etag),
    Json::string(self.spec.sha256),
    Json::string(self.chunk_size.to_string()),
    Json::array(records),
  ]).stringify()
}

///|
fn decimal(text : String) -> Int64 raise LedgerError {
  if text.is_empty() ||
    text.length() > 19 ||
    (text.length() > 1 && text[0] == '0') {
    raise InvalidCheckpoint("noncanonical decimal")
  }
  for c in text {
    if c < '0' || c > '9' {
      raise InvalidCheckpoint("expected decimal digits")
    }
  }
  @strconv.parse_int64(text) catch {
    _ => raise InvalidCheckpoint("decimal exceeds Int64")
  }
}

///|
/// Exact schema and object identity required. All recorded coverage starts
/// untrusted, reservations are discarded, and old capabilities cannot be reused.
pub fn restore(
  checkpoint : String,
  expected : ObjectSpec,
) -> Session raise LedgerError {
  if checkpoint.length() > 16000000 {
    raise InvalidCheckpoint("checkpoint exceeds 16M code units")
  }
  let value = @json.parse(checkpoint) catch {
    _ => raise InvalidCheckpoint("malformed JSON")
  }
  let (resource, length, etag, sha256, size, records) = match value {
    [
      String("MFL1"),
      String(resource),
      String(length),
      String(etag),
      String(sha256),
      String(size),
      Array(records),
    ] => (resource, length, etag, sha256, size, records)
    _ =>
      raise InvalidCheckpoint("unsupported version, field type or extra field")
  }
  let spec = ObjectSpec::new(resource, decimal(length), etag, sha256) catch {
    _ => raise InvalidCheckpoint("invalid object specification")
  }
  if spec != expected {
    raise InvalidCheckpoint(
      "object identity mismatch; retain input and restart explicitly",
    )
  }
  let chunk_size = decimal(size)
  if chunk_size > 4194304L {
    raise InvalidCheckpoint("unsupported chunk size")
  }
  let session = Session::new(spec, chunk_size=chunk_size.to_int()) catch {
    _ => raise InvalidCheckpoint("invalid block limits")
  }
  let mut previous = -1L
  for record in records {
    let (index, hash) = match record {
      [String(index), String(hash)] => (decimal(index), hash)
      _ => raise InvalidCheckpoint("invalid block record or extra field")
    }
    if index <= previous ||
      index >= session.blocks.length().to_int64() ||
      !valid_digest(hash) {
      raise InvalidCheckpoint(
        "duplicate, unsorted, out-of-bounds block or invalid digest",
      )
    }
    session.blocks[index.to_int()] = Unverified(hash)
    previous = index
  }
  session.recovering = true
  session
}
