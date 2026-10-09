///|
test "local repair requires verified source, matching layout and unchanged rereads" {
  let data = b"abcdefg"
  let object = spec(data)
  let indexer = @moonfetchledger.StorageIndexer::new(object, chunk_size=3)
  let target = @moonfetchledger.Session::new(object, chunk_size=3)
  let lease = target.reserve_missing().unwrap()
  try indexer.prepare_repair(target, lease, b"abc") catch {
    @moonfetchledger.Incomplete(_) => ()
    _ => fail("incorrect unverified-source diagnostic")
  } noraise {
    _ => fail("accepted partial source index")
  }
  while indexer.next_range() is Some(range) {
    indexer.push(payload(data, range))
  }
  for bad in [b"ab", b"xyz"] {
    try indexer.prepare_repair(target, lease, bad) catch {
      @moonfetchledger.InvalidResponse(_) => ()
      _ => fail("incorrect changed-source diagnostic")
    } noraise {
      _ => fail("accepted changed local read")
    }
    assert_eq(target.confirmed_bytes(), 0L)
  }
  let prepared = indexer.prepare_repair(target, lease, b"abc")
  target.commit_written(prepared, b"abc")
  target.commit_written(prepared, b"abc")
  assert_eq(target.confirmed_bytes(), 3L)
  let conflict = @moonfetchledger.Session::new(object, chunk_size=3)
  let conflict_lease = conflict.reserve_missing().unwrap()
  let old = conflict.prepare_chunk(
    conflict_lease,
    b"xyz",
    status=206,
    etag=object.etag,
    range=conflict_lease.range,
    total=object.length,
  )
  conflict.commit_written(old, b"xyz")
  let before = conflict.checkpoint()
  try indexer.prepare_repair(conflict, conflict_lease, b"abc") catch {
    @moonfetchledger.InvalidResponse(_) => ()
    _ => fail("incorrect conflicting duplicate diagnostic")
  } noraise {
    _ => fail("prepared a conflicting confirmed block for writing")
  }
  assert_eq(conflict.checkpoint(), before)
  for
    other in [
      @moonfetchledger.Session::new(object, chunk_size=2),
      @moonfetchledger.Session::new(spec(b"xxxxxxx"), chunk_size=3),
    ] {
    try
      indexer.prepare_repair(other, other.reserve_missing().unwrap(), b"abc")
    catch {
      @moonfetchledger.InvalidSpec(_) => ()
      _ => fail("incorrect source/target mismatch diagnostic")
    } noraise {
      _ => fail("accepted incompatible repair target")
    }
  }
  let another = @moonfetchledger.Session::new(object, chunk_size=3)
  try indexer.prepare_repair(another, lease, b"abc") catch {
    @moonfetchledger.StaleLease => ()
    _ => fail("incorrect foreign lease diagnostic")
  } noraise {
    _ => fail("accepted foreign lease")
  }
}

///|
test "local repair roundtrips all small layouts and rejects wrong whole digest" {
  for size in 1..<=65 {
    let data = Bytes::make(size, 65)
    for chunk in [1, 3, 16, 31] {
      let object = spec(data)
      let indexer = @moonfetchledger.StorageIndexer::new(
        object,
        chunk_size=chunk,
      )
      while indexer.next_range() is Some(range) {
        indexer.push(payload(data, range))
      }
      let target = @moonfetchledger.Session::new(object, chunk_size=chunk)
      while target.reserve_missing() is Some(lease) {
        let bytes = payload(data, lease.range)
        target.commit_written(
          indexer.prepare_repair(target, lease, bytes),
          bytes,
        )
      }
      target.verify_complete(range => payload(data, range))
      assert_eq(target.checkpoint(), indexer.finish().checkpoint())
    }
  }
  let object = spec(b"abc")
  let indexer = @moonfetchledger.StorageIndexer::new(object, chunk_size=3)
  indexer.push(b"xyz")
  let target = @moonfetchledger.Session::new(object, chunk_size=3)
  try
    indexer.prepare_repair(target, target.reserve_missing().unwrap(), b"xyz")
  catch {
    @moonfetchledger.DigestMismatch(_) => ()
    _ => fail("incorrect whole-source digest diagnostic")
  } noraise {
    _ => fail("repaired from untrusted source")
  }
}
