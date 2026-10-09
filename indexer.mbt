///|
/// Index existing storage without inventing HTTP response metadata. No session
/// or checkpoint is exposed until the trusted whole-file digest has matched.
pub struct StorageIndexer {
  priv session : Session
  priv verifier : Verifier
}

///|
pub fn StorageIndexer::new(
  spec : ObjectSpec,
  chunk_size? : Int = 1048576,
) -> StorageIndexer raise LedgerError {
  let session = Session::new(spec, chunk_size~)
  { session, verifier: Verifier::new(spec, chunk_size), }
}

///|
pub fn StorageIndexer::next_range(self : StorageIndexer) -> ByteRange? {
  self.verifier.next_range()
}

///|
/// Supply exactly the next range read from storage. Rejected lengths leave the
/// index and hash unchanged, permitting a corrected read to be supplied.
pub fn StorageIndexer::push(
  self : StorageIndexer,
  bytes : Bytes,
) -> Unit raise LedgerError {
  let range = match self.next_range() {
    Some(range) => range
    None => raise InvalidResponse("storage indexing has no remaining range")
  }
  self.verifier.push(bytes)
  let index = (range.start / self.session.chunk_size.to_int64()).to_int()
  self.session.blocks[index] = Confirmed(0L, digest(bytes))
  self.session.confirmed += range.length()
}

///|
/// Verify the entire digest and return a fresh complete session. Repeated finish
/// is deterministic; incorrect digests never expose partial confirmed coverage.
pub fn StorageIndexer::finish(
  self : StorageIndexer,
) -> Session raise LedgerError {
  self.verifier.finish()
  let result = Session::new(
    self.session.spec,
    chunk_size=self.session.chunk_size,
  )
  for i, block in self.session.blocks {
    result.blocks[i] = block
  }
  result.confirmed = self.session.spec.length
  result.search_start = result.blocks.length()
  result
}

///|
/// Prepare a local repair from an entirely verified storage index. Identity and
/// block layout must match the target. Re-read bytes must still match the indexed
/// block digest; rejected input leaves the lease available for a corrected read.
pub fn StorageIndexer::prepare_repair(
  self : StorageIndexer,
  target : Session,
  lease : Lease,
  bytes : Bytes,
) -> PreparedChunk raise LedgerError {
  self.verifier.finish()
  target.check_lease(lease)
  if target.spec != self.session.spec ||
    target.chunk_size != self.session.chunk_size {
    raise InvalidSpec(
      "repair source identity and block layout must match target",
    )
  }
  if bytes.length().to_int64() != lease.range.length() {
    raise InvalidResponse(
      "local repair read does not match reserved block length",
    )
  }
  let sha256 = digest(bytes)
  match target.blocks[lease.index] {
    Confirmed(_, old) if old != sha256 =>
      raise InvalidResponse("conflicting local repair duplicate block")
    _ => ()
  }
  match self.session.blocks[lease.index] {
    Confirmed(_, expected) if expected == sha256 => { lease, sha256, }
    _ => raise InvalidResponse("local repair source changed since verification")
  }
}
