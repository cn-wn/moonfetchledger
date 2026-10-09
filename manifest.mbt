///|
/// Deterministic release identity, without coverage, credentials or local paths.
/// Obtain the manifest or its exact-byte digest through an independent trusted
/// channel. Parsing alone does not authenticate a publisher.
pub fn ObjectSpec::to_manifest(self : ObjectSpec) -> String {
  Json::array([
    Json::string("MFLARTIFACT1"),
    Json::string(self.resource),
    Json::string(self.length.to_string()),
    Json::string(self.etag),
    Json::string(self.sha256),
  ]).stringify()
}

///|
/// Exact five-field schema; unknown fields/versions are refused, never discarded.
/// Length is a canonical decimal string so all targets preserve Int64 identity.
/// Accepts JSON whitespace but never normalizes resource or validator values.
pub fn ObjectSpec::from_manifest(text : String) -> ObjectSpec raise LedgerError {
  if text.length() > 65536 {
    raise InvalidManifest("manifest exceeds 65536 code units")
  }
  let value = @json.parse(text) catch {
    _ => raise InvalidManifest("malformed manifest JSON")
  }
  let (resource, length, etag, sha256) = match value {
    [
      String("MFLARTIFACT1"),
      String(resource),
      String(length),
      String(etag),
      String(sha256),
    ] => (resource, length, etag, sha256)
    _ =>
      raise InvalidManifest(
        "unsupported manifest version, field type or extra field",
      )
  }
  let length = decimal(length) catch {
    _ =>
      raise InvalidManifest(
        "manifest length must be canonical decimal in 0..Int64::max_value",
      )
  }
  ObjectSpec::new(resource, length, etag, sha256) catch {
    InvalidSpec(message) =>
      raise InvalidManifest("invalid manifest identity: " + message)
    other => raise other
  }
}
