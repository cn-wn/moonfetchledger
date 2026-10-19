///|
fn reference_options(values : Map[String, String]) -> Bool {
  values.contains("--write-block-reference") ||
  values.contains("--block-reference") ||
  values.contains("--block-reference-sha256")
}

///|
// Explicit offline publication, inspection or NEW checkpoint adoption. Validate
// every option before publication or artifact-sidecar access.
async fn reference_command(
  spec : @ledger.ObjectSpec,
  values : Map[String, String],
  auditing~ : Bool,
  adopting_reference~ : Bool,
) -> Unit {
  if values.get("--write-block-reference") is Some(destination) {
    if auditing || adopting_reference {
      fail("--write-block-reference cannot be combined with audit or adoption")
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
  if auditing == adopting_reference {
    fail(
      "block reference input requires exactly one of --audit or --adopt-with-reference",
    )
  }
  for key, _ in values {
    if !identity_option(key) &&
      key != "--block-reference" &&
      key != "--block-reference-sha256" {
      fail("option \{key} is unsupported with reference audit/adoption")
    }
  }
  let path = argument(values, "--block-reference")
  let reference = @host.load_block_reference(
    spec,
    path,
    argument(values, "--block-reference-sha256"),
  )
  protect_descriptor(path, values, "block reference")
  let output = argument(values, "--output")
  let report = if adopting_reference {
    @host.adopt_with_reference(reference, output)
  } else {
    @host.audit_with_reference(reference, output)
  }
  println(report.to_json().stringify())
}
