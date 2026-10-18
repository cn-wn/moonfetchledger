///|
async fn require_new_reference_checkpoint(output : String) -> Unit {
  for suffix in [".mfl", ".mfl.next", ".mfl.recovering"] {
    if @fs.exists(output + suffix) {
      raise InvalidInput(
        "reference adoption requires a new checkpoint; preserve existing checkpoint and temporary files",
      )
    }
  }
}

///|
/// Create a NEW recovery checkpoint from independently pinned complete block
/// records and actual artifact readback. Damaged/truncated content is permitted;
/// only matching blocks become confirmed. Artifact bytes are never written.
/// Existing checkpoints/temporaries are never replaced. A created lock may remain
/// after failure. Continue through ordinary receive/local repair APIs afterwards.
pub async fn adopt_with_reference(
  reference : @ledger.BlockReference,
  output : String,
) -> AuditReport {
  if output.is_empty() || !@fs.exists(output) || @fs.kind(output) != Regular {
    raise InvalidInput(
      "reference adoption requires an existing regular artifact",
    )
  }
  require_new_reference_checkpoint(output)
  let lock_path = output + ".mfl.lock"
  if @fs.exists(lock_path) && @fs.kind(lock_path) != Regular {
    raise InvalidInput("reference adoption requires a regular lock sidecar")
  }
  let lock = @fs.open(lock_path, mode=ReadWrite, create_mode=OpenOrCreate)
  defer lock.close()
  if lock.kind() != Regular {
    raise InvalidInput("reference adoption lock must remain regular")
  }
  if !lock.try_lock(Exclusive) {
    raise OutputLocked
  }
  // Recheck under the lock; another cooperating adopter may have published.
  require_new_reference_checkpoint(output)
  let (session, report) = inspect_reference(reference, output)
  if !report.output_present {
    raise InvalidInput(
      "artifact disappeared during reference adoption; retain inputs",
    )
  }
  let checkpoint = session.checkpoint()
  publish_new(output + ".mfl", file => file.write(checkpoint))
  report
}
