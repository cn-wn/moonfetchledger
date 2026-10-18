///|
fn reference_bytes(data : Bytes, mask : Int32) -> Bytes raise {
  let session = @moonfetchledger.Session::new(spec(data), chunk_size=3)
  let mut index = 0
  while session.reserve_missing() is Some(lease) {
    if (mask & (1 << index)) != 0 {
      let bytes = payload(data, lease.range)
      let prepared = session.prepare_chunk(
        lease,
        bytes,
        status=206,
        etag=session.spec.etag,
        range=lease.range,
        total=session.spec.length,
      )
      session.commit_written(prepared, bytes)
    }
    index += 1
  }
  @utf8.encode(session.checkpoint())
}

///|
test "block references round trip binary storage and preserve deterministic complete checkpoints" {
  for length in 0..<65 {
    let data = Bytes::makei(length, i => ((i * 37 + length) % 256).to_byte())
    for size in [1, 3, 16] {
      let indexer = @moonfetchledger.StorageIndexer::new(
        spec(data),
        chunk_size=size,
      )
      while indexer.next_range() is Some(range) {
        indexer.push(payload(data, range))
      }
      let reference = indexer.block_reference()
      let text = reference.to_checkpoint()
      assert_eq(text, indexer.finish().checkpoint())
      assert_eq(indexer.block_reference().to_checkpoint(), text)
      let bytes = @utf8.encode(text)
      let restored = @moonfetchledger.BlockReference::from_bytes(
        bytes,
        @moonfetchledger.digest(bytes),
        spec(data),
      )
      assert_eq(restored.to_checkpoint(), text)
      assert_eq(restored.spec, spec(data))
      assert_eq(restored.chunk_size, size)
      let session = restored.session()
      assert_eq(session.confirmed_bytes(), 0L)
      for range in session.recovery_ranges() {
        assert_true(session.reconcile_block(range, Some(payload(data, range))))
      }
      session.finish_recovery()
      session.verify_complete(range => payload(data, range))
      assert_eq(session.checkpoint(), text)
      assert_eq(restored.session().confirmed_bytes(), 0L)
    }
  }
}

///|
test "block reference publication is gated on full indexing and trusted whole digest" {
  let indexer = @moonfetchledger.StorageIndexer::new(spec(b"abc"), chunk_size=3)
  try indexer.block_reference() catch {
    @moonfetchledger.Incomplete(_) => ()
    _ => fail("wrong incomplete-reference diagnostic")
  } noraise {
    _ => fail("published an incomplete index")
  }
  indexer.push(b"xyz")
  try indexer.block_reference() catch {
    @moonfetchledger.DigestMismatch(_) => ()
    _ => fail("wrong untrusted-reference diagnostic")
  } noraise {
    _ => fail("published a bad whole digest")
  }
}

///|
test "references require complete exact MFL1 records and preserve authenticated whitespace" {
  let data = b"abcdefg"
  for mask in 0..<8 {
    let bytes = reference_bytes(data, mask)
    try
      @moonfetchledger.BlockReference::from_bytes(
        bytes,
        @moonfetchledger.digest(bytes),
        spec(data),
      )
    catch {
      @moonfetchledger.InvalidCheckpoint(_) => assert_true(mask != 7)
      _ => fail("wrong incomplete-reference diagnostic")
    } noraise {
      _ => assert_eq(mask, 7)
    }
  }
  let valid = reference_bytes(data, 7)
  let fields = match @json.parse(@utf8.decode(valid)) {
    Array(fields) => fields
    _ => fail("test checkpoint was not an array")
  }
  let malformed = [@utf8.encode(@utf8.decode(valid) + "null")]
  let extra = fields.copy()
  extra.push(Json::null())
  malformed.push(@utf8.encode(Json::array(extra).stringify()))
  for
    records in [
      Json::array([]),
      Json::array([
        Json::array([
          Json::string("0"),
          Json::string(@moonfetchledger.digest(b"abc")),
        ]),
        Json::array([
          Json::string("0"),
          Json::string(@moonfetchledger.digest(b"abc")),
        ]),
      ]),
      Json::array([
        Json::array([
          Json::string("3"),
          Json::string(@moonfetchledger.digest(b"abc")),
        ]),
      ]),
      Json::array([
        Json::array([
          Json::string("00"),
          Json::string(@moonfetchledger.digest(b"abc")),
        ]),
      ]),
    ] {
    let changed = fields.copy()
    changed[6] = records
    malformed.push(@utf8.encode(Json::array(changed).stringify()))
  }
  for bytes in malformed {
    try
      @moonfetchledger.BlockReference::from_bytes(
        bytes,
        @moonfetchledger.digest(bytes),
        spec(data),
      )
    catch {
      @moonfetchledger.InvalidCheckpoint(_) => ()
      _ => fail("wrong strict-reference diagnostic")
    } noraise {
      _ => fail("accepted unsupported reference data")
    }
  }
  let spaced = " \n" + @utf8.decode(valid) + "\t "
  let bytes = @utf8.encode(spaced)
  let reference = @moonfetchledger.BlockReference::from_bytes(
    bytes,
    @moonfetchledger.digest(bytes),
    spec(data),
  )
  assert_eq(reference.to_checkpoint(), spaced)
}

///|
test "reference pin precedes parsing and identity checks with bounded strict UTF-8" {
  let object = spec(b"abc")
  let bad = b"\xff"
  try
    @moonfetchledger.BlockReference::from_bytes(
      bad,
      @moonfetchledger.digest(b""),
      object,
    )
  catch {
    @moonfetchledger.InvalidCheckpoint(message) =>
      assert_true(message.contains("trusted byte pin"))
    _ => fail("wrong pin mismatch diagnostic")
  } noraise {
    _ => fail("accepted wrong pin")
  }
  try
    @moonfetchledger.BlockReference::from_bytes(
      bad,
      @moonfetchledger.digest(bad),
      object,
    )
  catch {
    @moonfetchledger.InvalidCheckpoint(message) =>
      assert_true(message.contains("strict UTF-8"))
    _ => fail("wrong UTF-8 diagnostic")
  } noraise {
    _ => fail("accepted malformed UTF-8")
  }
  let bytes = reference_bytes(b"abc", 1)
  for pin in ["", "A".repeat(64), "g".repeat(64), "0".repeat(63)] {
    try @moonfetchledger.BlockReference::from_bytes(bytes, pin, object) catch {
      @moonfetchledger.InvalidCheckpoint(message) =>
        assert_true(message.contains("lowercase"))
      _ => fail("wrong pin grammar diagnostic")
    } noraise {
      _ => fail("accepted malformed pin")
    }
  }
  try
    @moonfetchledger.BlockReference::from_bytes(
      bytes,
      @moonfetchledger.digest(bytes),
      spec(b"xyz"),
    )
  catch {
    @moonfetchledger.InvalidCheckpoint(message) =>
      assert_true(message.contains("identity mismatch"))
    _ => fail("wrong expected identity diagnostic")
  } noraise {
    _ => fail("accepted foreign identity")
  }
  try
    @moonfetchledger.BlockReference::from_bytes(
      Bytes::make(16000001, b' '),
      @moonfetchledger.digest(b""),
      object,
    )
  catch {
    @moonfetchledger.InvalidCheckpoint(message) =>
      assert_true(message.contains("16000000"))
    _ => fail("wrong reference byte-bound diagnostic")
  } noraise {
    _ => fail("accepted oversized reference")
  }
}

///|
test "reference sessions distrust records, recover independent masks and still require final SHA" {
  let data = b"abcdefg"
  let bytes = reference_bytes(data, 7)
  let reference = @moonfetchledger.BlockReference::from_bytes(
    bytes,
    @moonfetchledger.digest(bytes),
    spec(data),
  )
  for mask in 0..<8 {
    let session = reference.session()
    try session.reserve_missing() catch {
      @moonfetchledger.RecoveryRequired => ()
      _ => fail("wrong reference recovery gate")
    } noraise {
      _ => fail("trusted reference as actual local storage")
    }
    let mut expected = 0L
    for i, range in session.recovery_ranges() {
      let present = (mask & (1 << i)) != 0
      assert_eq(
        session.reconcile_block(
          range,
          if present {
            Some(payload(data, range))
          } else {
            Some(Bytes::make(range.length().to_int(), b'\xff'))
          },
        ),
        present,
      )
      if present {
        expected += range.length()
      }
    }
    session.finish_recovery()
    assert_eq(session.confirmed_bytes(), expected)
    assert_eq(reference.session().confirmed_bytes(), 0L)
  }
  let session = @moonfetchledger.Session::new(spec(b"abc"), chunk_size=3)
  let lease = session.reserve_missing().unwrap()
  session.commit_written(
    session.prepare_chunk(
      lease,
      b"xyz",
      status=206,
      etag=session.spec.etag,
      range=lease.range,
      total=3L,
    ),
    b"xyz",
  )
  let bytes = @utf8.encode(session.checkpoint())
  let bad_reference = @moonfetchledger.BlockReference::from_bytes(
    bytes,
    @moonfetchledger.digest(bytes),
    spec(b"abc"),
  )
  let target = bad_reference.session()
  assert_true(target.reconcile_block({ start: 0L, end: 3L, }, Some(b"xyz")))
  target.finish_recovery()
  try target.verify_complete(_ => b"xyz") catch {
    @moonfetchledger.DigestMismatch(_) => ()
    _ => fail("wrong final-integrity diagnostic")
  } noraise {
    _ => fail("equated authenticated block records with whole digest")
  }
}
