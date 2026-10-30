///|
fn check_checkpoint_blocks(blocks : Int32) -> Unit raise HostError {
  if blocks < 1 || blocks > 1024 {
    raise InvalidInput("checkpoint_blocks must be 1..1024")
  }
}

///|
priv struct CheckpointBatch {
  session : @ledger.Session
  file : @fs.File
  checkpoint : String
  limit : Int32
  pending : Array[(@ledger.PreparedChunk, @ledger.ByteRange)]
  mut bytes : Int64
}

///|
fn CheckpointBatch::new(
  session : @ledger.Session,
  file : @fs.File,
  checkpoint : String,
  limit : Int32,
) -> CheckpointBatch {
  { session, file, checkpoint, limit, pending: [], bytes: 0L, }
}

///|
// The owner serializes writes/flushes. No confirmed coverage or notification is
// published before data sync, independent readback and checkpoint replacement.
async fn CheckpointBatch::flush(
  self : CheckpointBatch,
) -> Array[@ledger.ByteRange] {
  if self.pending.is_empty() {
    return []
  }
  self.file.sync()
  let ranges = []
  for (prepared, range) in self.pending {
    self.session.commit_written(
      prepared,
      self.file.read_exactly_at(range.length().to_int(), position=range.start),
    )
    ranges.push(range)
  }
  save(self.session, self.checkpoint)
  self.pending.clear()
  self.bytes = 0L
  ranges
}

///|
async fn CheckpointBatch::append(
  self : CheckpointBatch,
  prepared : @ledger.PreparedChunk,
  range : @ledger.ByteRange,
  bytes : Bytes,
) -> Array[@ledger.ByteRange] {
  self.file.write_at(bytes, position=range.start)
  self.pending.push((prepared, range))
  self.bytes += range.length()
  if self.pending.length() >= self.limit || self.bytes >= 16777216L {
    self.flush()
  } else {
    []
  }
}
