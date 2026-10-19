///|
fn identity_option(key : String) -> Bool {
  [
    "--url", "--output", "--length", "--etag", "--sha256", "--manifest", "--manifest-sha256",
  ].contains(key)
}

///|
async fn specification(values : Map[String, String]) -> @ledger.ObjectSpec {
  if values.contains("--manifest") || values.contains("--manifest-sha256") {
    for key in ["--url", "--length", "--etag", "--sha256"] {
      if values.contains(key) {
        fail(
          "manifest and inline identity options are mutually exclusive; no overrides allowed",
        )
      }
    }
    if !values.contains("--manifest") || !values.contains("--manifest-sha256") {
      fail(
        "--manifest and independently trusted --manifest-sha256 are required together",
      )
    }
    let manifest = argument(values, "--manifest")
    let spec = @host.load_manifest(
      manifest,
      argument(values, "--manifest-sha256"),
    )
    protect_descriptor(manifest, values, "manifest")
    spec
  } else {
    @ledger.ObjectSpec::new(
      argument(values, "--url"),
      integer(argument(values, "--length"), "--length"),
      argument(values, "--etag"),
      argument(values, "--sha256"),
    )
  }
}

///|
// Protect the loaded descriptor from accidentally becoming an artifact, saved
// checkpoint, lock or export temporary. Resolve existing filesystem aliases.
async fn protect_descriptor(
  manifest : String,
  values : Map[String, String],
  role : String,
) -> Unit {
  let source = @fs.realpath(manifest).to_lower()
  let writes : Array[String] = []
  if values.get("--output") is Some(output) {
    writes.append([
      output,
      output + ".mfl",
      output + ".mfl.lock",
      output + ".mfl.next",
      output + ".mfl.recovering",
    ])
  }
  if values.get("--export-to") is Some(destination) {
    writes.append([destination, destination + ".next"])
  }
  if values.get("--write-block-reference") is Some(destination) {
    writes.append([destination, destination + ".next"])
  }
  for path in writes {
    if @fs.exists(path) && @fs.realpath(path).to_lower() == source {
      fail(
        "artifact/session/export paths must not alias the input \{role}; retain the release metadata",
      )
    }
  }
}
