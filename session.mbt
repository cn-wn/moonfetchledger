///|
/// Create a fixed-block sparse receiver. At most 100,000 blocks, 4 MiB each.
/// Calls are synchronous and must be serialized by the adapter; leases permit
/// concurrent network requests, not unsynchronized threads mutating a session.
pub fn Session::new(
  spec : ObjectSpec,
  chunk_size? : Int = 1048576,
) -> Session raise LedgerError {
  if chunk_size < 1 || chunk_size > 4194304 {
    raise InvalidSpec("chunk size must be 1..4194304 bytes")
  }
  let size = chunk_size.to_int64()
  let count = spec.length / size +
    (if spec.length % size == 0L { 0L } else { 1L })
  if count > 100000L {
    raise InvalidSpec("more than 100000 blocks; increase chunk size")
  }
  {
    spec,
    chunk_size,
    blocks: Array::make(count.to_int(), Missing),
    next_id: 1L,
    recovering: false,
    search_start: 0,
    confirmed: 0L,
  }
}

///|
fn Session::block_range(self : Session, index : Int) -> ByteRange {
  let start = index.to_int64() * self.chunk_size.to_int64()
  {
    start,
    end: start + (self.spec.length - start).min(self.chunk_size.to_int64()),
  }
}

///|
/// Reserve the earliest missing block, excluding all outstanding requests.
pub fn Session::reserve_missing(self : Session) -> Lease? raise LedgerError {
  if self.recovering {
    raise RecoveryRequired
  }
  for i in self.search_start..<self.blocks.length() {
    let block = self.blocks[i]
    if block is Missing {
      if self.next_id == 9223372036854775807L {
        raise InvalidSpec("lease counter exhausted; checkpoint and restore")
      }
      let id = self.next_id
      self.next_id += 1L
      self.blocks[i] = Reserved(id)
      self.search_start = i + 1
      return Some({ range: self.block_range(i), owner: self, index: i, id, })
    }
  }
  None
}

///|
fn Session::check_lease(
  self : Session,
  lease : Lease,
) -> Unit raise LedgerError {
  if !physical_equal(self, lease.owner) {
    raise StaleLease
  }
  match self.blocks[lease.index] {
    Reserved(id) | Confirmed(id, _) if id == lease.id => ()
    _ => raise StaleLease
  }
}

///|
/// Cancel an outstanding request. Confirmed data is never released.
pub fn Session::release(
  self : Session,
  lease : Lease,
) -> Unit raise LedgerError {
  self.check_lease(lease)
  match self.blocks[lease.index] {
    Reserved(_) => {
      self.blocks[lease.index] = Missing
      self.search_start = self.search_start.min(lease.index)
    }
    _ => raise StaleLease
  }
}

///|
/// Adapter supplies parsed Content-Range as half-open bounds and complete length.
/// Rejects full responses and representation changes before storage is touched.
pub fn Session::prepare_chunk(
  self : Session,
  lease : Lease,
  bytes : Bytes,
  status~ : Int,
  etag~ : String,
  range~ : ByteRange,
  total~ : Int64,
  content_encoding? : String = "identity",
) -> PreparedChunk raise LedgerError {
  self.check_lease(lease)
  if status != 206 {
    raise InvalidResponse("expected 206; restart explicitly on 200")
  }
  if etag != self.spec.etag || total != self.spec.length {
    raise InvalidResponse(
      "object version or length changed; restart explicitly",
    )
  }
  if content_encoding != "identity" {
    raise InvalidResponse("encoded representation unsupported")
  }
  if range != lease.range || bytes.length().to_int64() != range.length() {
    raise InvalidResponse(
      "Content-Range or body length does not match reserved block",
    )
  }
  let sha256 = digest(bytes)
  match self.blocks[lease.index] {
    Confirmed(_, old) if old != sha256 =>
      raise InvalidResponse("conflicting duplicate block")
    _ => ()
  }
  { lease, sha256, }
}

///|
/// Call only with bytes read back from lease.range after a successful write/sync.
/// Readback proves equality with the received payload, not durable-media honesty.
/// Repeating an identical commit is idempotent.
pub fn Session::commit_written(
  self : Session,
  prepared : PreparedChunk,
  readback : Bytes,
) -> Unit raise LedgerError {
  self.check_lease(prepared.lease)
  if readback.length().to_int64() != prepared.lease.range.length() ||
    digest(readback) != prepared.sha256 {
    raise ReadbackMismatch(prepared.lease.range.start)
  }
  match self.blocks[prepared.lease.index] {
    Confirmed(_, old) if old != prepared.sha256 =>
      raise InvalidResponse("conflicting commit")
    Reserved(_) => {
      self.blocks[prepared.lease.index] = Confirmed(
        prepared.lease.id,
        prepared.sha256,
      )
      self.confirmed += prepared.lease.range.length()
    }
    Confirmed(_, _) => ()
    _ => raise StaleLease
  }
}

///|
pub fn Session::confirmed_bytes(self : Session) -> Int64 {
  self.confirmed
}

///|
/// Restored blocks requiring readback, returned as a fresh array.
pub fn Session::recovery_ranges(self : Session) -> Array[ByteRange] {
  let ranges = []
  for i, block in self.blocks {
    if block is Unverified(_) {
      ranges.push(self.block_range(i))
    }
  }
  ranges
}

///|
/// Restore one block using actual storage. None means absent/truncated storage.
/// I/O errors must be propagated by the adapter, not converted to None.
pub fn Session::reconcile_block(
  self : Session,
  range : ByteRange,
  readback : Bytes?,
) -> Bool raise LedgerError {
  if !self.recovering ||
    range.start < 0L ||
    range.start % self.chunk_size.to_int64() != 0L {
    raise InvalidResponse("range is not pending recovery")
  }
  let index = range.start / self.chunk_size.to_int64()
  if index >= self.blocks.length().to_int64() {
    raise InvalidResponse("recovery range out of bounds")
  }
  let i = index.to_int()
  if self.block_range(i) != range {
    raise InvalidResponse("recovery range mismatch")
  }
  let expected = match self.blocks[i] {
    Unverified(hash) => hash
    _ => raise InvalidResponse("block is not pending recovery")
  }
  let valid = match readback {
    Some(bytes) =>
      bytes.length().to_int64() == range.length() && digest(bytes) == expected
    None => false
  }
  self.blocks[i] = if valid { Confirmed(0L, expected) } else { Missing }
  if valid {
    self.confirmed += range.length()
  }
  valid
}

///|
/// Returns invalidated ranges from a caller-owned report; no silent recovery.
pub fn Session::finish_recovery(self : Session) -> Unit raise LedgerError {
  for block in self.blocks {
    if block is Unverified(_) {
      raise RecoveryRequired
    }
  }
  self.recovering = false
}

///|
/// Bounded-memory verification. The callback must read the requested stored range;
/// short reads and I/O exceptions abort verification without declaring completion.
pub fn Session::verify_complete(
  self : Session,
  read_at : (ByteRange) -> Bytes raise,
) -> Unit raise {
  let verifier = self.verifier()
  while verifier.next_range() is Some(range) {
    verifier.push(read_at(range))
  }
  verifier.finish()
}
