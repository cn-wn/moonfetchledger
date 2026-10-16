///|
/// Sequential bounded-memory verifier suitable for asynchronous storage adapters.
pub struct Verifier {
  priv spec : ObjectSpec
  priv chunk_size : Int32
  priv hasher : @crypto.SHA256
  priv mut position : Int64
  priv mut result : String?
}

///|
pub fn Session::verifier(self : Session) -> Verifier raise LedgerError {
  if self.recovering {
    raise RecoveryRequired
  }
  let confirmed = self.confirmed_bytes()
  if confirmed != self.spec.length {
    raise Incomplete(self.spec.length - confirmed)
  }
  Verifier::new(self.spec, self.chunk_size)
}

///|
fn Verifier::new(spec : ObjectSpec, chunk_size : Int32) -> Verifier {
  {
    spec,
    chunk_size,
    hasher: @crypto.SHA256::new(),
    position: 0L,
    result: None,
  }
}

///|
pub fn Verifier::next_range(self : Verifier) -> ByteRange? {
  if self.position == self.spec.length {
    return None
  }
  Some({
    start: self.position,
    end: self.position +
    (self.spec.length - self.position).min(self.chunk_size.to_int64()),
  })
}

///|
/// Feed exactly the next requested range. Bad lengths do not advance the hash.
pub fn Verifier::push(self : Verifier, bytes : Bytes) -> Unit raise LedgerError {
  let range = match self.next_range() {
    Some(range) => range
    None => raise InvalidResponse("verification has no remaining range")
  }
  if bytes.length().to_int64() != range.length() {
    raise ReadbackMismatch(range.start)
  }
  self.hasher.update(bytes)
  self.position = range.end
}

///|
pub fn Verifier::finish(self : Verifier) -> Unit raise LedgerError {
  if self.position != self.spec.length {
    raise Incomplete(self.spec.length - self.position)
  }
  let actual = match self.result {
    Some(hash) => hash
    None => {
      let hash = @crypto.bytes_to_hex_string(self.hasher.finalize())
      self.result = Some(hash)
      hash
    }
  }
  if actual != self.spec.sha256 {
    raise DigestMismatch(actual)
  }
}
