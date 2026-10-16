///|
/// Adopt an existing regular file into a new recovery session. Read-only source,
/// exclusive cooperative lock, exact length and trusted SHA-256 are required.
/// Existing checkpoints/temporary files are refused, never replaced. On failure
/// the original file is unchanged; a newly created lock sidecar may remain.
pub async fn adopt(
  spec : @ledger.ObjectSpec,
  output : String,
  chunk_size~ : Int32 = 65536,
) -> Unit {
  let indexer = @ledger.StorageIndexer::new(spec, chunk_size~)
  if output.is_empty() || !@fs.exists(output) || @fs.kind(output) != Regular {
    raise InvalidInput("adopt requires an existing regular output file")
  }
  let lock = @fs.open(
    output + ".mfl.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  defer lock.close()
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  let checkpoint = output + ".mfl"
  if @fs.exists(checkpoint) ||
    @fs.exists(checkpoint + ".next") ||
    @fs.exists(checkpoint + ".recovering") {
    raise InvalidInput(
      "adopt requires a new checkpoint; existing session/temporary data must be retained",
    )
  }
  let file = @fs.open(output, mode=ReadOnly)
  defer file.close()
  if file.size() != spec.length {
    raise InvalidInput(
      "adopt requires exact file length; refusing to truncate or pad",
    )
  }
  while indexer.next_range() is Some(range) {
    indexer.push(
      file.read_exactly_at(range.length().to_int(), position=range.start),
    )
  }
  let session = indexer.finish()
  if file.size() != spec.length {
    raise InvalidInput("output length changed during adoption")
  }
  let text = session.checkpoint()
  publish_new(checkpoint, destination => destination.write(text))
}
