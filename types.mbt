///|
/// Failures preserve the session's confirmed coverage. Storage failures belong
/// to the caller; release its lease before retrying. Checkpoint failures require
/// retaining the input and explicitly starting a new session.
pub suberror LedgerError {
  InvalidSpec(String)
  InvalidCheckpoint(String)
  InvalidManifest(String)
  StaleLease
  InvalidResponse(String)
  ReadbackMismatch(Int64)
  RecoveryRequired
  Incomplete(Int64)
  DigestMismatch(String)
} derive(Debug)

///|
/// Identity includes the resource, representation length, strong HTTP validator
/// and independently obtained SHA-256. The ETag is not an integrity digest.
pub struct ObjectSpec {
  resource : String
  length : Int64
  etag : String
  sha256 : String
} derive(Eq, Debug)

///|
pub fn ObjectSpec::new(
  resource : String,
  length : Int64,
  etag : String,
  sha256 : String,
) -> ObjectSpec raise LedgerError {
  if resource.is_empty() || resource.length() > 8192 {
    raise InvalidSpec("resource must contain 1..8192 code units")
  }
  if length < 0L {
    raise InvalidSpec("length must be nonnegative")
  }
  if !strong_etag(etag) {
    raise InvalidSpec("a quoted strong ETag is required")
  }
  if !valid_digest(sha256) {
    raise InvalidSpec("SHA-256 must be 64 lowercase hex digits")
  }
  { resource, length, etag, sha256, }
}

///|
fn strong_etag(tag : String) -> Bool {
  if tag.length() < 2 ||
    tag.length() > 1024 ||
    !tag.has_prefix("\"") ||
    !tag.has_suffix("\"") {
    return false
  }
  for i in 1..<(tag.length() - 1) {
    let c = tag[i].to_int()
    if c < 33 || c == 34 || c == 127 || c > 255 {
      return false
    }
  }
  true
}

///|
fn valid_digest(text : String) -> Bool {
  if text.length() != 64 {
    return false
  }
  for c in text {
    if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      return false
    }
  }
  true
}

///|
/// SHA-256 of bytes, without decoding text. Provided for storage integration.
pub fn digest(bytes : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
}

///|
/// Half-open byte range [start, end).
pub(all) struct ByteRange {
  start : Int64
  end : Int64
} derive(Eq, Debug)

///|
pub fn ByteRange::length(self : ByteRange) -> Int64 {
  self.end - self.start
}

///|
priv enum Block {
  Missing
  Reserved(Int64)
  Confirmed(Int64, String)
  Unverified(String)
}

///|
pub struct Session {
  spec : ObjectSpec
  chunk_size : Int32
  priv blocks : Array[Block]
  priv mut next_id : Int64
  priv mut recovering : Bool
  priv mut search_start : Int32
  priv mut confirmed : Int64
}

///|
/// Session-bound capability; cannot be constructed or reused across restores.
pub struct Lease {
  range : ByteRange
  priv owner : Session
  priv index : Int32
  priv id : Int64
}

///|
pub struct PreparedChunk {
  priv lease : Lease
  priv sha256 : String
}

///|
pub(all) struct RecoveryReport {
  retained_bytes : Int64
  invalidated : Array[ByteRange]
} derive(Debug)

///|
pub extend LedgerError with Debug::{to_repr}

///|
pub extend ObjectSpec with Eq::{equal, not_equal}

///|
pub extend ObjectSpec with Debug::{to_repr}

///|
pub extend ByteRange with Eq::{equal, not_equal}

///|
pub extend ByteRange with Debug::{to_repr}

///|
pub extend RecoveryReport with Debug::{to_repr}
