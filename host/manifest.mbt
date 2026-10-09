///|
/// Publish a new deterministic UTF-8 manifest and return its exact-byte SHA-256.
/// Existing destinations/temporary files are preserved. Distribute the returned
/// pin independently; storing it beside an untrusted manifest does not add trust.
pub async fn write_manifest(spec : @ledger.ObjectSpec, path : String) -> String {
  if path.is_empty() {
    raise InvalidInput("manifest destination must not be empty")
  }
  let bytes = @utf8.encode(spec.to_manifest())
  if bytes.length() > 65536 {
    raise InvalidInput("encoded manifest exceeds 65536 bytes")
  }
  publish_new(path, file => file.write(bytes))
  @ledger.digest(bytes)
}

///|
/// Read at most 65536 bytes from a regular file. Verify the independently trusted
/// exact-byte digest before strict UTF-8 decoding or schema parsing. No source,
/// output or checkpoint writes; filesystem errors propagate.
pub async fn load_manifest(
  path : String,
  expected_sha256 : String,
) -> @ledger.ObjectSpec {
  if expected_sha256.length() != 64 {
    raise InvalidInput(
      "manifest pin requires 64 lowercase hexadecimal SHA-256 digits",
    )
  }
  for c in expected_sha256 {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      raise InvalidInput(
        "manifest pin requires 64 lowercase hexadecimal SHA-256 digits",
      )
    }
  }
  if path.is_empty() || @fs.kind(path) != Regular {
    raise InvalidInput("manifest input must be a regular file")
  }
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != Regular {
    raise InvalidInput("manifest input must remain a regular file")
  }
  let size = file.size()
  if size > 65536L {
    raise InvalidInput("manifest exceeds 65536 bytes")
  }
  let bytes = file.read_exactly(size.to_int())
  if file.read_some(max_len=1) is Some(_) || file.size() != size {
    raise InvalidInput(
      "manifest length changed while reading; retry with a stable file",
    )
  }
  if @ledger.digest(bytes) != expected_sha256 {
    raise InvalidInput(
      "manifest SHA-256 differs from trusted pin; retain input and obtain the expected release metadata",
    )
  }
  let text = @utf8.decode(bytes) catch {
    _ =>
      raise InvalidInput(
        "manifest requires strict UTF-8; malformed bytes are not replaced",
      )
  }
  @ledger.ObjectSpec::from_manifest(text)
}
