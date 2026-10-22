///|
pub suberror ReleaseError {
  InvalidRelease(String)
  UntrustedRelease(String)
} derive(Debug)

///|
pub extend ReleaseError with Debug::{to_repr}

///|
/// Signed authority for ONE product/channel release and its exact delta bytes.
/// Versions are monotonic positive Int64 values, not semantic-version strings.
pub struct Release {
  product : String
  channel : String
  version : Int64
  issued_at : Int64
  expires_at : Int64
  metadata_url : String
  metadata_sha256 : String
}

///|
fn label_ok(text : String) -> Bool {
  !text.is_empty() &&
  text.length() <= 128 &&
  text
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '.' ||
    c == '_' ||
    c == '-'
  })
}

///|
pub fn Release::new(
  product : String,
  channel : String,
  version : Int64,
  issued_at : Int64,
  expires_at : Int64,
  metadata_url : String,
  metadata_sha256 : String,
) -> Release raise ReleaseError {
  if !label_ok(product) ||
    !label_ok(channel) ||
    version < 1L ||
    issued_at < 0L ||
    expires_at <= issued_at ||
    expires_at - issued_at > 31536000L {
    raise InvalidRelease(
      "product/channel require 1..128 ASCII identifier characters; version >=1; validity must be 1..31536000 seconds",
    )
  }
  if metadata_url.is_empty() ||
    metadata_url.length() > 8192 ||
    !(metadata_url.has_prefix("http://") || metadata_url.has_prefix("https://")) ||
    !metadata_url
    .iter()
    .all(c => {
      c.to_int() >= 33 && c.to_int() <= 126 && c != '@' && c != '#' && c != '\\'
    }) {
    raise InvalidRelease(
      "metadata URL requires ASCII HTTP(S), no credentials, fragments or controls",
    )
  }
  ignore(decode_hex(metadata_sha256, 32))
  {
    product,
    channel,
    version,
    issued_at,
    expires_at,
    metadata_url,
    metadata_sha256,
  }
}

///|
fn hex_digit(c : UInt16) -> Int32 raise ReleaseError {
  if c.to_int() >= 48 && c.to_int() <= 57 {
    c.to_int() - 48
  } else if c.to_int() >= 97 && c.to_int() <= 102 {
    c.to_int() - 87
  } else {
    raise InvalidRelease("hex fields require canonical lowercase hexadecimal")
  }
}

///|
fn decode_hex(text : String, size : Int32) -> Bytes raise ReleaseError {
  if text.length() != size * 2 {
    raise InvalidRelease("incorrect hex field length")
  }
  Bytes::makei(size, i => {
    ((hex_digit(text[i * 2]) << 4) | hex_digit(text[i * 2 + 1])).to_byte()
  })
}

///|
fn encode_hex(bytes : Bytes) -> String {
  let alphabet = "0123456789abcdef"
  let out = StringBuilder()
  for b in bytes {
    let high = b.to_int() >> 4
    let low = b.to_int() & 15
    out.write_string(alphabet[high:high + 1].to_owned())
    out.write_string(alphabet[low:low + 1].to_owned())
  }
  out.to_string()
}

///|
fn Release::payload(self : Release) -> String {
  Json::array([
    Json::string("MFLRELEASE-PAYLOAD1"),
    Json::string(self.product),
    Json::string(self.channel),
    Json::string(self.version.to_string()),
    Json::string(self.issued_at.to_string()),
    Json::string(self.expires_at.to_string()),
    Json::string(self.metadata_url),
    Json::string(self.metadata_sha256),
  ]).stringify()
}

///|
/// Deterministic plain Ed25519 over a domain prefix plus canonical payload.
/// Private seeds are 32 bytes; callers own their storage and secret handling.
pub fn Release::sign(
  self : Release,
  private_seed : Bytes,
) -> Bytes raise ReleaseError {
  let payload = self.payload()
  let signature = @ed25519.sign(
    private_seed,
    b"MFLRELEASE1\x00" + @utf8.encode(payload),
  ) catch {
    _ => raise InvalidRelease("signing requires a 32-byte Ed25519 seed")
  }
  let bytes = @utf8.encode(
    Json::array([
      Json::string("MFLRELEASE1"),
      Json::string(payload),
      Json::string(encode_hex(signature)),
    ]).stringify(),
  )
  if bytes.length() > 16384 {
    raise InvalidRelease(
      "signed release exceeds 16384 bytes; shorten metadata URL",
    )
  }
  bytes
}

///|
fn decimal(text : String) -> Int64 raise ReleaseError {
  let n = @strconv.parse_int64(text) catch {
    _ =>
      raise InvalidRelease(
        "release numbers require canonical nonnegative Int64 decimal",
      )
  }
  if n < 0L || n.to_string() != text {
    raise InvalidRelease("noncanonical release number")
  }
  n
}

///|
/// A pinned public key, expected product/channel and minimum acceptable version.
/// Obtain this policy independently of the untrusted release server.
pub struct ReleaseTrust {
  product : String
  channel : String
  minimum_version : Int64
  key_sha256 : String
  priv key : @ed25519.VerifyingKey
}

///|
pub fn ReleaseTrust::new(
  public_key : Bytes,
  product : String,
  channel : String,
  minimum_version~ : Int64 = 1L,
) -> ReleaseTrust raise ReleaseError {
  if !label_ok(product) || !label_ok(channel) || minimum_version < 1L {
    raise InvalidRelease(
      "invalid pinned release product/channel or minimum version",
    )
  }
  let key = @ed25519.VerifyingKey::from_public_key(public_key) catch {
    _ =>
      raise InvalidRelease(
        "public key must be a valid prime-order 32-byte Ed25519 key",
      )
  }
  {
    product,
    channel,
    minimum_version,
    key_sha256: @ledger.digest(public_key),
    key,
  }
}

///|
/// Only signature-checked, policy-bound releases can construct this capability.
pub struct ApprovedRelease {
  release : Release
  payload_sha256 : String
  key_sha256 : String
}

///|
/// Check exclusive expiry with an independently trusted Unix clock.
/// Input is canonical UTF-8 JSON, <=16384 bytes; unknown fields are refused.
pub fn ReleaseTrust::verify(
  self : ReleaseTrust,
  bytes : Bytes,
  now : Int64,
) -> ApprovedRelease raise ReleaseError {
  if bytes.length() > 16384 || now < 0L {
    raise InvalidRelease("release exceeds 16384 bytes or clock is negative")
  }
  let text = @utf8.decode(bytes) catch {
    _ => raise InvalidRelease("release requires strict UTF-8")
  }
  let envelope = @json.parse(text) catch {
    _ => raise InvalidRelease("malformed release envelope")
  }
  let (payload, signature) = match envelope {
    [String("MFLRELEASE1"), String(payload), String(signature)] =>
      (payload, decode_hex(signature, 64))
    _ =>
      raise InvalidRelease("unsupported release envelope, type or extra field")
  }
  if envelope.stringify() != text {
    raise InvalidRelease("release envelope must be canonical JSON")
  }
  if !self.key.verify(b"MFLRELEASE1\x00" + @utf8.encode(payload), signature) {
    raise UntrustedRelease("invalid release signature; retain local files")
  }
  let value = @json.parse(payload) catch {
    _ => raise InvalidRelease("malformed signed release payload")
  }
  let release = match value {
    [
      String("MFLRELEASE-PAYLOAD1"),
      String(product),
      String(channel),
      String(version),
      String(issued),
      String(expires),
      String(url),
      String(pin),
    ] =>
      Release::new(
        product,
        channel,
        decimal(version),
        decimal(issued),
        decimal(expires),
        url,
        pin,
      )
    _ => raise InvalidRelease("unsupported signed payload, type or extra field")
  }
  if release.payload() != payload {
    raise InvalidRelease("signed payload must be canonical JSON")
  }
  if release.product != self.product ||
    release.channel != self.channel ||
    release.version < self.minimum_version ||
    now < release.issued_at ||
    now >= release.expires_at {
    raise UntrustedRelease(
      "release product/channel/version or validity window violates pinned policy",
    )
  }
  {
    release,
    payload_sha256: @ledger.digest(@utf8.encode(payload)),
    key_sha256: self.key_sha256,
  }
}
