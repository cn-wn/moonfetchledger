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
