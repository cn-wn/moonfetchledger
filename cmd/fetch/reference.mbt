///|
fn reference_options(values : Map[String, String]) -> Bool {
  values.contains("--write-block-reference") ||
  values.contains("--block-reference") ||
  values.contains("--block-reference-sha256")
}

///|
// A complete independent publisher/auditor workflow, separate from saved local
// progress. Validate every option before publication or artifact-sidecar access.
async fn reference_command(
  spec : @ledger.ObjectSpec,
  values : Map[String, String],
  auditing~ : Bool,
) -> Unit {
  if values.get("--write-block-reference") is Some(destination) {
    if auditing {
      fail("--write-block-reference cannot be combined with --audit")
    }
    for key, _ in values {
      if !identity_option(key) &&
        key != "--write-block-reference" &&
        key != "--chunk-size" {
        fail("option \{key} is unsupported with --write-block-reference")
      }
    }
    let pin = @host.write_block_reference(
      spec,
      argument(values, "--output"),
      destination,
      chunk_size=small(values, "--chunk-size", 65536),
    )
    println("block-reference: sha256=\{pin}")
    return
  }
  if !values.contains("--block-reference") ||
    !values.contains("--block-reference-sha256") {
    fail(
      "--block-reference and independently trusted --block-reference-sha256 are required together",
    )
  }
  if !auditing {
    fail("block reference input requires --audit")
  }
  for key, _ in values {
    if !identity_option(key) &&
      key != "--block-reference" &&
      key != "--block-reference-sha256" {
      fail("option \{key} is unsupported with reference audit")
    }
  }
  let path = argument(values, "--block-reference")
  let reference = @host.load_block_reference(
    spec,
    path,
    argument(values, "--block-reference-sha256"),
  )
  protect_descriptor(path, values, "block reference")
  println(
    @host.audit_with_reference(reference, argument(values, "--output"))
    .to_json()
    .stringify(),
  )
}
