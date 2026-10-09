///|
test "manifest round trips preserve Int64 and exact identity on every target" {
  let hash = @moonfetchledger.digest(b"abc")
  for
    length in [
      0L, 1L, 4095L, 4096L, 4097L, 9007199254740991L, 9007199254740992L, 9007199254740993L,
      9223372036854775807L,
    ] {
    for
      resource in [
        "https://example.test/a?q=1&x=2",
        "opaque:雪/😀",
        "literal:\n\t\\\"",
        "x".repeat(8192),
      ] {
      let spec = @moonfetchledger.ObjectSpec::new(
        resource, length, "\"v1-é\"", hash,
      )
      let text = spec.to_manifest()
      let restored = @moonfetchledger.ObjectSpec::from_manifest(text)
      assert_eq(restored, spec)
      assert_eq(restored.to_manifest(), text)
      assert_eq(
        @moonfetchledger.ObjectSpec::from_manifest(" \n" + text + "\t "),
        spec,
      )
      assert_true(text.contains("\"" + length.to_string() + "\""))
    }
  }
  let spec = @moonfetchledger.ObjectSpec::new(
    "https://example.test/a", 3L, "\"v1\"", hash,
  )
  assert_eq(
    spec.to_manifest(),
    "[\"MFLARTIFACT1\",\"https://example.test/a\",\"3\",\"\\\"v1\\\"\",\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"]",
  )
}

///|
test "manifest refuses unsupported structure and malformed identity without silent loss" {
  let hash = @moonfetchledger.digest(b"")
  let spec = @moonfetchledger.ObjectSpec::new(
    "https://example.test/a", 0L, "\"v1\"", hash,
  )
  let valid = spec.to_manifest()
  for
    text in [
      "",
      "[",
      "null",
      "{}",
      "{\"url\":\"a\",\"url\":\"b\"}",
      "[]",
      valid + "null",
      valid[0:valid.length() - 1].to_owned() + ",\"extra\"]",
      "[\"MFLARTIFACT2\",\"a\",\"0\",\"\\\"v1\\\"\",\"" + hash + "\"]",
      " ".repeat(65537),
    ] {
    try @moonfetchledger.ObjectSpec::from_manifest(text) catch {
      @moonfetchledger.InvalidManifest(_) => ()
      _ => fail("incorrect manifest structure diagnostic")
    } noraise {
      _ => fail("accepted unsupported manifest data")
    }
  }
  for
    length in [
      "", "-1", "+1", "01", " 1", "1 ", "1.0", "1e3", "9223372036854775808", "99999999999999999999",
    ] {
    let text = Json::array([
      Json::string("MFLARTIFACT1"),
      Json::string("a"),
      Json::string(length),
      Json::string("\"v1\""),
      Json::string(hash),
    ]).stringify()
    try @moonfetchledger.ObjectSpec::from_manifest(text) catch {
      @moonfetchledger.InvalidManifest(_) => ()
      _ => fail("incorrect decimal diagnostic")
    } noraise {
      _ => fail("accepted invalid decimal")
    }
  }
  let fields : Array[Json] = [
    Json::string("MFLARTIFACT1"),
    Json::string("a"),
    Json::string("0"),
    Json::string("\"v1\""),
    Json::string(hash),
  ]
  for index in 0..<5 {
    let changed = fields.copy()
    changed[index] = Json::number(0)
    try
      @moonfetchledger.ObjectSpec::from_manifest(
        Json::array(changed).stringify(),
      )
    catch {
      @moonfetchledger.InvalidManifest(_) => ()
      _ => fail("incorrect field type diagnostic")
    } noraise {
      _ => fail("accepted a non-string field")
    }
  }
  for
    (index, value) in [
      (1, ""),
      (1, "x".repeat(8193)),
      (3, "W/\"v1\""),
      (3, "unquoted"),
      (4, "a".repeat(63)),
      (4, "A".repeat(64)),
    ] {
    let changed = fields.copy()
    changed[index] = Json::string(value)
    try
      @moonfetchledger.ObjectSpec::from_manifest(
        Json::array(changed).stringify(),
      )
    catch {
      @moonfetchledger.InvalidManifest(_) => ()
      _ => fail("incorrect identity diagnostic")
    } noraise {
      _ => fail("accepted an invalid identity")
    }
  }
  assert_eq(@moonfetchledger.ObjectSpec::from_manifest(valid), spec)
}

///|
test "manifest identity leaves checkpoint format and recovery behavior unchanged" {
  let data = b"abc"
  let spec = @moonfetchledger.ObjectSpec::new(
    "https://example.test/a",
    3L,
    "\"v1\"",
    @moonfetchledger.digest(data),
  )
  let parsed = @moonfetchledger.ObjectSpec::from_manifest(spec.to_manifest())
  let session = @moonfetchledger.Session::new(parsed, chunk_size=3)
  let lease = session.reserve_missing().unwrap()
  let prepared = session.prepare_chunk(
    lease,
    data,
    status=206,
    etag=parsed.etag,
    range=lease.range,
    total=3L,
  )
  session.commit_written(prepared, data)
  let checkpoint = session.checkpoint()
  let restored = @moonfetchledger.restore(checkpoint, spec)
  assert_true(
    restored.reconcile_block(restored.recovery_ranges()[0], Some(data)),
  )
  restored.finish_recovery()
  restored.verify_complete(_ => data)
  assert_eq(restored.checkpoint(), checkpoint)
}
