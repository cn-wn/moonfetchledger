///|
/// Authenticated target-block index for cross-version reuse. The byte pin must
/// arrive through an independent trusted channel; this format is not a signature
/// and is not a zsync control file. MFL1 checkpoints remain unchanged.
pub struct DeltaReference {
  spec : ObjectSpec
  chunk_size : Int32
  priv reference : BlockReference
  priv weak : Array[UInt32]
  priv strong : Array[String]
}

///|
/// Streaming publisher. No metadata is released before whole-source verification.
pub struct DeltaIndexer {
  priv indexer : StorageIndexer
  priv weak : Array[UInt32]
}

///|
pub fn DeltaIndexer::new(
  spec : ObjectSpec,
  chunk_size~ : Int32 = 65536,
) -> DeltaIndexer raise LedgerError {
  { indexer: StorageIndexer::new(spec, chunk_size~), weak: [], }
}

///|
pub fn DeltaIndexer::next_range(self : DeltaIndexer) -> ByteRange? {
  self.indexer.next_range()
}

///|
pub fn DeltaIndexer::push(
  self : DeltaIndexer,
  bytes : Bytes,
) -> Unit raise LedgerError {
  self.indexer.push(bytes)
  self.weak.push(delta_weak(bytes))
}

///|
fn delta_reference(
  reference : BlockReference,
  weak : Array[UInt32],
) -> DeltaReference raise LedgerError {
  let session = reference.session()
  if weak.length() != session.blocks.length() {
    raise InvalidManifest(
      "delta index must contain exactly one rolling checksum per target block",
    )
  }
  let strong = session.blocks.map(block => {
    match block {
      Unverified(hash) => hash
      _ =>
        raise InvalidManifest(
          "delta reference requires complete target block records",
        )
    }
  })
  {
    spec: reference.spec,
    chunk_size: reference.chunk_size,
    reference,
    weak: weak.copy(),
    strong,
  }
}

///|
pub fn DeltaIndexer::finish(
  self : DeltaIndexer,
) -> DeltaReference raise LedgerError {
  delta_reference(self.indexer.block_reference(), self.weak)
}

///|
/// Exact four-field positional schema, canonical output and full-width checksums.
pub fn DeltaReference::to_bytes(self : DeltaReference) -> Bytes {
  @utf8.encode(
    Json::array([
      Json::string("MFLDELTA1"),
      Json::string(self.spec.to_manifest()),
      Json::string(self.reference.to_checkpoint()),
      Json::array(self.weak.map(v => Json::string(v.to_string()))),
    ]).stringify(),
  )
}

///|
/// Authenticate before UTF-8 or JSON parsing. Unknown fields and incomplete block
/// indexes are rejected. The authenticated identity includes URL, ETag and SHA-256.
pub fn DeltaReference::from_bytes(
  bytes : Bytes,
  expected_sha256 : String,
) -> DeltaReference raise LedgerError {
  if !valid_digest(expected_sha256) || bytes.length() > 16000000 {
    raise InvalidManifest(
      "delta reference requires a lowercase SHA-256 pin and at most 16000000 bytes",
    )
  }
  if digest(bytes) != expected_sha256 {
    raise InvalidManifest(
      "delta reference differs from trusted byte pin; retain input",
    )
  }
  let text = @utf8.decode(bytes) catch {
    _ => raise InvalidManifest("delta reference requires strict UTF-8")
  }
  let value = @json.parse(text) catch {
    _ => raise InvalidManifest("malformed delta reference JSON")
  }
  let (manifest, checkpoint, records) = match value {
    [String("MFLDELTA1"), String(manifest), String(checkpoint), Array(records)] =>
      (manifest, checkpoint, records)
    _ =>
      raise InvalidManifest(
        "unsupported delta reference version, field type or extra field",
      )
  }
  let spec = ObjectSpec::from_manifest(manifest)
  let encoded = @utf8.encode(checkpoint)
  let reference = BlockReference::from_bytes(encoded, digest(encoded), spec)
  if records.length() != reference.session().blocks.length() {
    raise InvalidManifest(
      "delta index requires exactly one rolling checksum per target block",
    )
  }
  let weak = records.map(v => {
    let text = match v {
      String(s) => s
      _ =>
        raise InvalidManifest(
          "rolling checksum must be a canonical decimal string",
        )
    }
    let n = decimal(text)
    if n > 4294967295L {
      raise InvalidManifest("rolling checksum exceeds UInt32")
    }
    n.to_int().reinterpret_as_uint()
  })
  delta_reference(reference, weak)
}

///|
pub fn DeltaReference::block_reference(self : DeltaReference) -> BlockReference {
  self.reference
}

///|
/// Revalidate seed bytes immediately before writing. A rolling match alone never
/// authorizes reuse. The lease is bound to the authenticated target and layout.
pub fn DeltaReference::prepare_reuse(
  self : DeltaReference,
  target : Session,
  lease : Lease,
  bytes : Bytes,
) -> PreparedChunk raise LedgerError {
  target.check_lease(lease)
  if target.spec != self.spec || target.chunk_size != self.chunk_size {
    raise InvalidSpec(
      "seed reuse target identity and block layout must match delta reference",
    )
  }
  if bytes.length().to_int64() != lease.range.length() ||
    digest(bytes) != self.strong[lease.index] {
    raise InvalidResponse(
      "seed block changed or differs from authenticated target; retain old file and retry",
    )
  }
  { lease, sha256: self.strong[lease.index], }
}

///|
// Two 16-bit sums with wrapping arithmetic. A filter only, never an integrity hash.
fn delta_weak(bytes : Bytes) -> UInt32 {
  let mut a = 0U
  let mut b = 0U
  for byte in bytes {
    a = (a + byte.to_int().reinterpret_as_uint()) & 65535U
    b = (b + a) & 65535U
  }
  (b << 16) | a
}
