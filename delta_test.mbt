///|
fn delta_index(
  data : Bytes,
  size : Int32,
) -> @moonfetchledger.DeltaReference raise {
  let spec = @moonfetchledger.ObjectSpec::new(
    "https://example.test/v2",
    data.length().to_int64(),
    "\"v2\"",
    @moonfetchledger.digest(data),
  )
  let indexer = @moonfetchledger.DeltaIndexer::new(spec, chunk_size=size)
  while indexer.next_range() is Some(r) {
    indexer.push(data[r.start.to_int():r.end.to_int()].to_owned())
  }
  indexer.finish()
}

///|
fn scanned(
  reference : @moonfetchledger.DeltaReference,
  seed : Bytes,
  stride : Int32,
) -> @moonfetchledger.SeedPlan raise {
  let scanner = reference.scanner()
  let mut offset = 0
  while offset < seed.length() {
    let end = (offset + stride).min(seed.length())
    scanner.push(seed[offset:end].to_owned())
    offset = end
  }
  scanner.finish()
}

///|
test "rolling sums wrap correctly across large windows and read boundaries" {
  let data = Bytes::makei(70001, i => ((i * 31 + i / 257) % 256).to_byte())
  let seed = b"shifted-prefix" + data
  for size in [257, 4096, 65536] {
    let reference = delta_index(data, size)
    for stride in [13, 65536] {
      assert_eq(
        scanned(reference, seed, stride).reused_bytes,
        data.length().to_int64(),
      )
    }
  }
}

///|
test "shifted, reordered, duplicated and short target blocks reuse first matching bytes" {
  let reference = delta_index(b"abcDEFabc!", 3)
  let plan = scanned(reference, b"xx!yyDEF--abc", 2)
  assert_eq(plan.reused_bytes, 10L)
  assert_eq(plan.scanned_bytes, 13L)
  assert_eq(plan.matches(), [
    { source: { start: 10L, end: 13L, }, target: { start: 0L, end: 3L, }, },
    { source: { start: 5L, end: 8L, }, target: { start: 3L, end: 6L, }, },
    { source: { start: 10L, end: 13L, }, target: { start: 6L, end: 9L, }, },
    { source: { start: 2L, end: 3L, }, target: { start: 9L, end: 10L, }, },
  ])
  let snapshot = plan.matches()
  snapshot.clear()
  assert_eq(plan.matches().length(), 4)
}

///|
test "streaming seed scan agrees with exhaustive byte matching across layouts" {
  for length in 0..<66 {
    let data = Bytes::makei(length, i => {
      ((i * 73 + i / 7 + length) % 256).to_byte()
    })
    let split = length / 2
    let seed = b"prefix" +
      data[split:].to_owned() +
      b"insert" +
      data[:split].to_owned() +
      b"suffix"
    for size in [1, 3, 8, 16] {
      let reference = delta_index(data, size)
      let encoded = reference.to_bytes()
      let restored = @moonfetchledger.DeltaReference::from_bytes(
        encoded,
        @moonfetchledger.digest(encoded),
      )
      assert_eq(restored.to_bytes(), encoded)
      let expected : Array[@moonfetchledger.SeedMatch] = []
      let mut start = 0
      while start < length {
        let end = (start + size).min(length)
        for at in 0..<(seed.length() - (end - start) + 1) {
          if seed[at:at + end - start] == data[start:end] {
            expected.push({
              source: {
                start: at.to_int64(),
                end: (at + end - start).to_int64(),
              },
              target: { start: start.to_int64(), end: end.to_int64(), },
            })
            break
          }
        }
        start = end
      }
      for stride in [1, 7, 65536] {
        let plan = scanned(restored, seed, stride)
        assert_eq(plan.matches(), expected)
        assert_eq(
          plan.reused_bytes,
          expected.iter().fold(init=0L, (n, r) => n + r.target.length()),
        )
      }
    }
  }
}

///|
test "weak checksum collisions never confirm wrong content and finish rejects later input" {
  // [10,20,30] and [11,18,31] have identical two-sum rolling checksums.
  let reference = delta_index(b"\x0a\x14\x1e", 3)
  assert_eq(scanned(reference, b"\x0b\x12\x1f", 1).reused_bytes, 0L)
  let scanner = reference.scanner()
  scanner.push(b"\x0b\x12\x1f--\x0a\x14\x1e")
  let plan = scanner.finish()
  assert_eq(plan.matches()[0].source.start, 5L)
  assert_eq(scanner.finish().matches(), plan.matches())
  try scanner.push(b"x") catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong scanner error")
  } noraise {
    _ => fail("accepted input after finish")
  }
  assert_eq(scanner.finish().matches(), plan.matches())
}

///|
test "delta publisher refuses bad lengths and wrong whole digest and recovers after short push" {
  let data = b"abcde"
  let spec = @moonfetchledger.ObjectSpec::new(
    "v2",
    5L,
    "\"v2\"",
    @moonfetchledger.digest(data),
  )
  let indexer = @moonfetchledger.DeltaIndexer::new(spec, chunk_size=3)
  try indexer.push(b"ab") catch {
    @moonfetchledger.ReadbackMismatch(_) => ()
    _ => fail("wrong length error")
  } noraise {
    _ => fail("accepted short block")
  }
  indexer.push(b"abc")
  try indexer.finish() catch {
    @moonfetchledger.Incomplete(_) => ()
    _ => fail("wrong incomplete error")
  } noraise {
    _ => fail("published incomplete index")
  }
  indexer.push(b"de")
  assert_eq(indexer.finish().to_bytes(), indexer.finish().to_bytes())
  let bad = @moonfetchledger.DeltaIndexer::new(spec, chunk_size=5)
  bad.push(b"xxxxx")
  try bad.finish() catch {
    @moonfetchledger.DigestMismatch(_) => ()
    _ => fail("wrong digest error")
  } noraise {
    _ => fail("published wrong source")
  }
}

///|
test "strict delta input refuses unauthenticated, malformed, incomplete and extra data" {
  let reference = delta_index(b"abcde", 3)
  let valid = reference.to_bytes()
  try
    @moonfetchledger.DeltaReference::from_bytes(
      b"\xff",
      @moonfetchledger.digest(valid),
    )
  catch {
    @moonfetchledger.InvalidManifest(s) =>
      assert_true(s.contains("trusted byte pin"))
    _ => fail("wrong pin error")
  } noraise {
    _ => fail("parsed before pin check")
  }
  let manifest = reference.spec.to_manifest()
  let cp = reference.block_reference().to_checkpoint()
  let partial = @moonfetchledger.Session::new(reference.spec, chunk_size=3).checkpoint()
  for
    value in [
      Json::array([
        Json::string("MFLDELTA1"),
        Json::string(manifest),
        Json::string(partial),
        Json::array([Json::string("0"), Json::string("0")]),
      ]),
      Json::array([
        Json::string("MFLDELTA2"),
        Json::string(manifest),
        Json::string(cp),
        Json::array([]),
      ]),
      Json::array([
        Json::string("MFLDELTA1"),
        Json::string(manifest),
        Json::string(cp),
        Json::array([]),
      ]),
      Json::array([
        Json::string("MFLDELTA1"),
        Json::string(manifest),
        Json::string(cp),
        Json::array([Json::string("01"), Json::string("0")]),
      ]),
      Json::array([
        Json::string("MFLDELTA1"),
        Json::string(manifest),
        Json::string(cp),
        Json::array([Json::string("4294967296"), Json::string("0")]),
      ]),
      Json::array([
        Json::string("MFLDELTA1"),
        Json::string(manifest),
        Json::string(cp),
        Json::array([Json::number(0), Json::string("0")]),
      ]),
      Json::array([
        Json::string("MFLDELTA1"),
        Json::string(manifest),
        Json::string(cp),
        Json::array([]),
        Json::null(),
      ]),
    ] {
    let bytes = @utf8.encode(value.stringify())
    try
      @moonfetchledger.DeltaReference::from_bytes(
        bytes,
        @moonfetchledger.digest(bytes),
      )
    catch {
      @moonfetchledger.InvalidManifest(_)
      | @moonfetchledger.InvalidCheckpoint(_) => ()
      _ => fail("wrong schema error")
    } noraise {
      _ => fail("accepted unsupported metadata")
    }
  }
  for bytes in [b"\xff", b"[", Bytes::make(16000001, b'x')] {
    try
      @moonfetchledger.DeltaReference::from_bytes(
        bytes,
        @moonfetchledger.digest(bytes),
      )
    catch {
      @moonfetchledger.InvalidManifest(_) => ()
      _ => fail("wrong input error")
    } noraise {
      _ => fail("accepted invalid bytes")
    }
  }
  assert_eq(
    @moonfetchledger.DeltaReference::from_bytes(
      valid,
      @moonfetchledger.digest(valid),
    ).to_bytes(),
    valid,
  )
}

///|
test "targeted leases and reused bytes preserve existing reservation semantics" {
  let reference = delta_index(b"abcdefg", 3)
  let session = @moonfetchledger.Session::new(reference.spec, chunk_size=3)
  let range : @moonfetchledger.ByteRange = { start: 3L, end: 6L, }
  let lease = session.reserve_range(range).unwrap()
  assert_true(session.reserve_range(range) is None)
  try reference.prepare_reuse(session, lease, b"xxx") catch {
    @moonfetchledger.InvalidResponse(_) => ()
    _ => fail("wrong changed-seed error")
  } noraise {
    _ => fail("accepted changed seed")
  }
  session.commit_written(
    reference.prepare_reuse(session, lease, b"def"),
    b"def",
  )
  assert_true(session.reserve_range(range) is None)
  assert_eq(session.reserve_missing().unwrap().range.start, 0L)
  let before = session.checkpoint()
  let invalid : Array[@moonfetchledger.ByteRange] = [
    { start: -1L, end: 2L, },
    { start: 1L, end: 4L, },
    { start: 6L, end: 8L, },
    { start: 7L, end: 7L, },
  ]
  for bad in invalid {
    try session.reserve_range(bad) catch {
      @moonfetchledger.InvalidSpec(_) => ()
      _ => fail("wrong range error")
    } noraise {
      _ => fail("accepted invalid range")
    }
    assert_eq(session.checkpoint(), before)
  }
  let restored = @moonfetchledger.restore(before, reference.spec)
  try restored.reserve_range(range) catch {
    @moonfetchledger.RecoveryRequired => ()
    _ => fail("wrong recovery error")
  } noraise {
    _ => fail("reserved before recovery")
  }
}
