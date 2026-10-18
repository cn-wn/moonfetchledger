///|
/// Immutable, complete block records authenticated by an independent byte pin.
/// Uses the existing MFL1 schema, but is not a local progress checkpoint. Loading
/// a reference never confirms local storage; every fresh session starts recovery.
pub struct BlockReference {
  spec : ObjectSpec
  chunk_size : Int32
  priv checkpoint : String
}

///|
/// Publish block records only after the entire indexed source digest verifies.
/// Repeated calls produce identical MFL1 bytes and independent recovery sessions.
pub fn StorageIndexer::block_reference(
  self : StorageIndexer,
) -> BlockReference raise LedgerError {
  let complete = self.finish()
  {
    spec: complete.spec,
    chunk_size: complete.chunk_size,
    checkpoint: complete.checkpoint(),
  }
}

///|
/// Authenticate exact bytes BEFORE UTF-8/schema decoding. The pin must come from
/// a separate trusted channel. Require the expected identity and every block,
/// including the short final block. Partial checkpoints are not references.
pub fn BlockReference::from_bytes(
  bytes : Bytes,
  expected_sha256 : String,
  expected : ObjectSpec,
) -> BlockReference raise LedgerError {
  if !valid_digest(expected_sha256) {
    raise InvalidCheckpoint(
      "block reference pin must be 64 lowercase SHA-256 hex digits",
    )
  }
  if bytes.length() > 16000000 {
    raise InvalidCheckpoint("block reference exceeds 16000000 bytes")
  }
  if digest(bytes) != expected_sha256 {
    raise InvalidCheckpoint(
      "block reference differs from trusted byte pin; retain input",
    )
  }
  let checkpoint = @utf8.decode(bytes) catch {
    _ =>
      raise InvalidCheckpoint(
        "block reference requires strict UTF-8; retain input",
      )
  }
  let session = restore(checkpoint, expected)
  for block in session.blocks {
    if !(block is Unverified(_)) {
      raise InvalidCheckpoint(
        "block reference requires every block record; partial progress is not a reference",
      )
    }
  }
  { spec: expected, chunk_size: session.chunk_size, checkpoint, }
}

///|
/// Producers emit canonical MFL1; consumers retain the exact authenticated text,
/// including whitespace. Do not recompute a supplied byte pin from re-encoded JSON.
pub fn BlockReference::to_checkpoint(self : BlockReference) -> String {
  self.checkpoint
}

///|
/// Return a fresh session with all records untrusted until actual block readback.
/// Caller must reconcile storage and finish recovery before reserving repairs.
pub fn BlockReference::session(
  self : BlockReference,
) -> Session raise LedgerError {
  restore(self.checkpoint, self.spec)
}
