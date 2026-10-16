///|
// Every native session reader uses the same handle for kind, bounded reads and
// size checks. A path stat followed by read_file can consume unbounded growth.
// Cooperative locks do not exclude external writers: detect length changes,
// but do not claim to detect same-size concurrent modifications or path swaps.
async fn load_checkpoint(
  path : String,
  spec : @ledger.ObjectSpec,
) -> @ledger.Session {
  if @fs.kind(path) != Regular {
    raise InvalidInput("checkpoint must be a regular file; retain input")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular {
    raise InvalidInput("checkpoint must be a regular file; retain input")
  }
  let size = file.size()
  if size > 16000000L {
    raise CheckpointTooLarge
  }
  let bytes = file.read_exactly_at(size.to_int(), position=0L)
  let probe = FixedArray::make(1, b'\x00')
  if file.read_at(probe, position=size) != 0 || file.size() != size {
    raise InvalidInput("checkpoint length changed while reading; retain input")
  }
  let text = @utf8.decode(bytes) catch {
    _ =>
      raise InvalidInput(
        "checkpoint requires strict UTF-8; retain malformed input",
      )
  }
  @ledger.restore(text, spec)
}
