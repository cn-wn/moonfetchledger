///|
fn seed() -> Bytes {
  Bytes::makei(32, i => i.to_byte())
}

///|
test "URL label hex key and application domain errors never authorize a release" {
  for
    (product, url, pin) in [
      ("", "https://e.test/m", @ledger.digest(b"")),
      ("p".repeat(129), "https://e.test/m", @ledger.digest(b"")),
      ("bad/name", "https://e.test/m", @ledger.digest(b"")),
      ("p", "file:///m", @ledger.digest(b"")),
      ("p", "https://u:secret@e.test/m", @ledger.digest(b"")),
      ("p", "https://e.test/m#f", @ledger.digest(b"")),
      ("p", "https://e.test/m", "A".repeat(64)),
      ("p", "https://e.test/m", "0".repeat(63)),
    ] {
    try @release.Release::new(product, "c", 1L, 0L, 1L, url, pin) catch {
      @release.InvalidRelease(_) => ()
      _ => fail("wrong field error")
    } noraise {
      _ => fail("accepted invalid descriptor fields")
    }
  }
  let trust = @release.ReleaseTrust::new(
    @ed25519.derive_public_key(seed()),
    "datasets",
    "stable",
  )
  let envelope = @json.parse(@utf8.decode(descriptor().sign(seed())))
  guard envelope is [_, String(payload), _] else { fail("wrong schema") }
  let raw_signature = @ed25519.sign(seed(), @utf8.encode(payload))
  let cross_protocol = @utf8.encode(
    Json::array([
      Json::string("MFLRELEASE1"),
      Json::string(payload),
      Json::string(@crypto.bytes_to_hex_string(raw_signature)),
    ]).stringify(),
  )
  try trust.verify(cross_protocol, 100L) catch {
    @release.UntrustedRelease(_) => ()
    _ => fail("wrong application-domain error")
  } noraise {
    _ => fail("accepted signature without domain prefix")
  }
}

///|
fn descriptor(
  version~ : Int64 = 2L,
  product~ : String = "datasets",
  channel~ : String = "stable",
) -> @release.Release raise {
  @release.Release::new(
    product,
    channel,
    version,
    100L,
    200L,
    "https://example.test/v2.delta",
    @ledger.digest(b"delta"),
  )
}

///|
test "signed release deterministic roundtrip binds publisher product channel version and time" {
  let key = @ed25519.derive_public_key(seed())
  let trust = @release.ReleaseTrust::new(
    key,
    "datasets",
    "stable",
    minimum_version=2L,
  )
  let bytes = descriptor().sign(seed())
  assert_eq(bytes, descriptor().sign(seed()))
  for now in [100L, 101L, 199L] {
    let checked = trust.verify(bytes, now)
    assert_eq(checked.release.version, 2L)
    assert_eq(checked.release.sign(seed()), bytes)
    assert_eq(checked.key_sha256, @ledger.digest(key))
  }
  for now in [0L, 99L, 200L, 9223372036854775807L] {
    try trust.verify(bytes, now) catch {
      @release.UntrustedRelease(_) => ()
      _ => fail("wrong clock rejection")
    } noraise {
      _ => fail("accepted outside validity window")
    }
  }
  for
    other in [
      descriptor(version=1L),
      descriptor(product="other"),
      descriptor(channel="beta"),
    ] {
    try trust.verify(other.sign(seed()), 100L) catch {
      @release.UntrustedRelease(_) => ()
      _ => fail("wrong policy rejection")
    } noraise {
      _ => fail("accepted wrong release policy")
    }
  }
  let wrong_key = @ed25519.derive_public_key(Bytes::make(32, b'x'))
  try
    @release.ReleaseTrust::new(wrong_key, "datasets", "stable").verify(
      bytes, 100L,
    )
  catch {
    @release.UntrustedRelease(_) => ()
    _ => fail("wrong signature rejection")
  } noraise {
    _ => fail("accepted foreign publisher")
  }
}

///|
test "tamper malformed unknown and noncanonical fields fail without poisoning later verification" {
  let trust = @release.ReleaseTrust::new(
    @ed25519.derive_public_key(seed()),
    "datasets",
    "stable",
  )
  let signed = descriptor().sign(seed())
  let text = @utf8.decode(signed)
  let mutations = [
    b"\xff",
    b"[]",
    b"[\"MFLRELEASE2\"]",
    signed + b" ",
    @utf8.encode(text.replace_all(old="datasets", new="tampered")),
    @utf8.encode(text.replace_all(old="MFLRELEASE1", new="MFLRELEASE0")),
    Bytes::make(16385, b'x'),
    signed[:signed.length() - 1].to_owned(),
  ]
  for bytes in mutations {
    try trust.verify(bytes, 100L) catch {
      @release.InvalidRelease(_) | @release.UntrustedRelease(_) => ()
    } noraise {
      _ => fail("accepted malformed release")
    }
    assert_eq(trust.verify(signed, 100L).release.version, 2L)
  }
  let envelope = @json.parse(text)
  guard envelope is [_, String(payload), _] else { fail("wrong writer schema") }
  for
    payload in [
      payload + " ",
      payload.replace_all(old="\"2\"", new="\"02\""),
      payload.replace_all(old="\"200\"", new="\"100\""),
      payload.replace_all(old="MFLRELEASE-PAYLOAD1", new="MFLRELEASE-PAYLOAD2"),
      payload[:payload.length() - 1].to_owned() + ",\"extra\"]",
    ] {
    let sig = @ed25519.sign(seed(), b"MFLRELEASE1\x00" + @utf8.encode(payload))
    let bytes = @utf8.encode(
      Json::array([
        Json::string("MFLRELEASE1"),
        Json::string(payload),
        Json::string(@crypto.bytes_to_hex_string(sig)),
      ]).stringify(),
    )
    try trust.verify(bytes, 100L) catch {
      @release.InvalidRelease(_) => ()
      _ => fail("wrong authenticated malformed error")
    } noraise {
      _ => fail("accepted unsupported signed data")
    }
  }
}

///|
test "descriptor boundaries require exact key sizes monotonic numbers identifiers URL and hex" {
  let oversized = @release.Release::new(
    "p",
    "c",
    1L,
    0L,
    1L,
    "https://e.test/" + "\"".repeat(8000),
    @ledger.digest(b""),
  )
  try oversized.sign(seed()) catch {
    @release.InvalidRelease(_) => ()
    _ => fail("wrong encoded publication bound error")
  } noraise {
    _ => fail("published a descriptor larger than the verification bound")
  }
  for
    (version, issued, expires) in [
      (0L, 1L, 2L),
      (1L, -1L, 2L),
      (1L, 2L, 2L),
      (1L, 2L, 1L),
      (1L, 0L, 31536001L),
    ] {
    try
      @release.Release::new(
        "p",
        "c",
        version,
        issued,
        expires,
        "https://e.test/m",
        @ledger.digest(b""),
      )
    catch {
      @release.InvalidRelease(_) => ()
      _ => fail("wrong boundary error")
    } noraise {
      _ => fail("accepted invalid numbers")
    }
  }
  let maximum = @release.Release::new(
    "p".repeat(128),
    "c",
    9223372036854775807L,
    9223372036854775806L,
    9223372036854775807L,
    "https://e.test/m",
    @ledger.digest(b""),
  )
  let trust = @release.ReleaseTrust::new(
    @ed25519.derive_public_key(seed()),
    "p".repeat(128),
    "c",
  )
  assert_eq(
    trust.verify(maximum.sign(seed()), 9223372036854775806L).release.version,
    9223372036854775807L,
  )
  for size in [0, 31, 33] {
    try descriptor().sign(Bytes::make(size, b'x')) catch {
      @release.InvalidRelease(_) => ()
      _ => fail("wrong seed length error")
    } noraise {
      _ => fail("accepted malformed seed")
    }
  }
  try @release.ReleaseTrust::new(Bytes::make(32, b'\x00'), "p", "c") catch {
    @release.InvalidRelease(_) => ()
    _ => fail("wrong small-order key error")
  } noraise {
    _ => fail("accepted invalid key")
  }
}
