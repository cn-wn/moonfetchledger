///|
test "indexing gates sessions on completeness and permits corrected short reads" {
  let data = b"abcdefg"
  let indexer = @moonfetchledger.StorageIndexer::new(spec(data), chunk_size=3)
  let first = indexer.next_range().unwrap()
  try indexer.finish() catch {
    @moonfetchledger.Incomplete(7L) => ()
    _ => fail("incorrect incomplete-index diagnostic")
  } noraise {
    _ => fail("exposed unverified session")
  }
  try indexer.push(b"ab") catch {
    @moonfetchledger.ReadbackMismatch(0L) => ()
    _ => fail("incorrect short-read diagnostic")
  } noraise {
    _ => fail("accepted short storage read")
  }
  assert_eq(indexer.next_range(), Some(first))
  while indexer.next_range() is Some(range) {
    indexer.push(payload(data, range))
  }
  let complete = indexer.finish()
  assert_eq(complete.confirmed_bytes(), 7L)
  assert_true(complete.unconfirmed_ranges().is_empty())
  assert_true(complete.reserve_missing() is None)
  complete.verify_complete(range => payload(data, range))
  assert_eq(indexer.finish().checkpoint(), complete.checkpoint())
  try indexer.push(b"extra") catch {
    @moonfetchledger.InvalidResponse(_) => ()
    _ => fail("incorrect extra-read diagnostic")
  } noraise {
    _ => fail("accepted data after indexing finished")
  }
  assert_eq(indexer.finish().checkpoint(), complete.checkpoint())
}

///|
test "wrong digest never exposes indexed coverage, including empty storage" {
  for (expected, actual) in [(b"abc", b"xyz"), (b"", b"")] {
    let object = if expected.is_empty() {
      @moonfetchledger.ObjectSpec::new(
        "https://example.test/a",
        0L,
        "\"v1\"",
        @moonfetchledger.digest(b"wrong"),
      )
    } else {
      spec(expected)
    }
    let indexer = @moonfetchledger.StorageIndexer::new(object, chunk_size=3)
    while indexer.next_range() is Some(range) {
      indexer.push(payload(actual, range))
    }
    for _ in 0..<2 {
      try indexer.finish() catch {
        @moonfetchledger.DigestMismatch(hash) =>
          assert_eq(hash, @moonfetchledger.digest(actual))
        _ => fail("incorrect indexing-integrity diagnostic")
      } noraise {
        _ => fail("exposed session for untrusted content")
      }
    }
  }
}

///|
test "binary indexing matches reception checkpoints and round-trips restoration" {
  for length in 0..<129 {
    let bytes = Bytes::makei(length, i => ((i * 73 + length) % 256).to_byte())
    let object = spec(bytes)
    for size in [1, 3, 16, 31] {
      let indexer = @moonfetchledger.StorageIndexer::new(
        object,
        chunk_size=size,
      )
      while indexer.next_range() is Some(range) {
        indexer.push(payload(bytes, range))
      }
      let indexed = indexer.finish()
      let received = @moonfetchledger.Session::new(object, chunk_size=size)
      while received.reserve_missing() is Some(lease) {
        commit(received, lease, bytes)
      }
      let checkpoint = indexed.checkpoint()
      assert_eq(checkpoint, received.checkpoint())
      let restored = @moonfetchledger.restore(checkpoint, object)
      for range in restored.recovery_ranges() {
        assert_true(
          restored.reconcile_block(range, Some(payload(bytes, range))),
        )
      }
      restored.finish_recovery()
      restored.verify_complete(range => payload(bytes, range))
      assert_eq(restored.checkpoint(), checkpoint)
    }
  }
}
