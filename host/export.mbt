///|
async fn canonical_entry(path : String) -> String {
  let entry = @path.Path(path)
  let parent = @fs.realpath(entry.dirname().to_string())
  @path.Path(parent)
  .join(@path.Path(entry.basename().to_owned()))
  .normalize()
  .to_string()
  .to_lower()
}

///|
/// Copy a complete retained artifact to a new destination. Source and checkpoint
/// are preserved. Hold the source's shared lock throughout reconciliation and
/// copy; verify copied bytes and synced destination readback before publication.
/// No network, no replacement of existing destination or temporary files.
pub async fn export_verified(
  spec : @ledger.ObjectSpec,
  output : String,
  destination : String,
) -> Unit {
  if output.is_empty() ||
    destination.is_empty() ||
    destination == output ||
    destination == output + ".mfl" ||
    destination == output + ".mfl.lock" ||
    destination == output + ".mfl.next" {
    raise InvalidInput(
      "export requires a new destination outside the source session's paths",
    )
  }
  if @fs.exists(destination) || @fs.exists(destination + ".next") {
    raise InvalidInput(
      "export destination or temporary file exists; refusing to replace it",
    )
  }
  let checkpoint = output + ".mfl"
  if !@fs.exists(output) ||
    !@fs.exists(checkpoint) ||
    !@fs.exists(output + ".mfl.lock") ||
    @fs.kind(output) != Regular {
    raise InvalidInput(
      "export requires an existing regular output, checkpoint and lock sidecar",
    )
  }
  let source_entry = canonical_entry(output)
  let destination_entry = canonical_entry(destination)
  if [
      source_entry,
      source_entry + ".mfl",
      source_entry + ".mfl.lock",
      source_entry + ".mfl.next",
    ].contains(destination_entry) {
    raise InvalidInput("export destination aliases a source session path")
  }
  let lock = @fs.open(output + ".mfl.lock", mode=ReadOnly)
  defer lock.close()
  if !lock.try_lock(Shared) {
    raise OutputLocked
  }
  let session = load_checkpoint(checkpoint, spec)
  let source = @fs.open(output, mode=ReadOnly)
  defer source.close()
  let size = source.size()
  if size != spec.length {
    raise InvalidInput(
      "export requires exact source length; refusing to trim or pad",
    )
  }
  for range in session.recovery_ranges() {
    if !session.reconcile_block(
        range,
        Some(
          source.read_exactly_at(range.length().to_int(), position=range.start),
        ),
      ) {
      raise InvalidInput(
        "recorded block [\{range.start},\{range.end}) no longer matches storage; audit and repair before export",
      )
    }
  }
  session.finish_recovery()
  let copied = session.verifier() // rejects missing/corrupt coverage before creating a temporary file
  publish_new(destination, target => {
    while copied.next_range() is Some(range) {
      let bytes = source.read_exactly_at(
        range.length().to_int(),
        position=range.start,
      )
      target.write_at(bytes, position=range.start)
      copied.push(bytes)
    }
    copied.finish()
    target.sync()
    let readback = session.verifier()
    while readback.next_range() is Some(range) {
      readback.push(
        target.read_exactly_at(range.length().to_int(), position=range.start),
      )
    }
    readback.finish()
    if source.size() != spec.length || target.size() != spec.length {
      raise InvalidInput("source or destination length changed during export")
    }
  })
}
