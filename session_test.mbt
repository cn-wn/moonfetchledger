///|
fn spec(bytes : Bytes) -> @moonfetchledger.ObjectSpec raise {
  @moonfetchledger.ObjectSpec::new(
    "https://example.test/a?x=\"中\"",
    bytes.length().to_int64(),
    "\"v1\"",
    @moonfetchledger.digest(bytes),
  )
}

///|
fn rejects(action : () -> Unit raise) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("expected diagnostic")
  }
}

///|
fn payload(bytes : Bytes, range : @moonfetchledger.ByteRange) -> Bytes {
  bytes[range.start.to_int():range.end.to_int()].to_owned()
}

///|
fn commit(
  session : @moonfetchledger.Session,
  lease : @moonfetchledger.Lease,
  bytes : Bytes,
) -> Unit raise {
  let chunk = payload(bytes, lease.range)
  let prepared = session.prepare_chunk(
    lease,
    chunk,
    status=206,
    etag="\"v1\"",
    range=lease.range,
    total=bytes.length().to_int64(),
  )
  session.commit_written(prepared, chunk)
}

///|
test "published SHA-256 vectors and binary bytes" {
  assert_eq(
    @moonfetchledger.digest(b""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  assert_eq(
    @moonfetchledger.digest(b"abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  assert_true(
    @moonfetchledger.digest(b"\x00\xff") != @moonfetchledger.digest(b"\x00"),
  )
}

///|
test "out of order reservations, readback and duplicate commits" {
  let data = b"abcdefg"
  let s = @moonfetchledger.Session::new(spec(data), chunk_size=3)
  let a = s.reserve_missing().unwrap()
  let b = s.reserve_missing().unwrap()
  let c = s.reserve_missing().unwrap()
  assert_true(s.reserve_missing() is None)
  assert_eq(a.range.start, 0L)
  assert_eq(b.range.start, 3L)
  assert_eq(c.range.length(), 1L)
  commit(s, c, data)
  assert_eq(s.confirmed_bytes(), 1L)
  commit(s, b, data)
  commit(s, a, data)
  commit(s, a, data)
  assert_eq(s.confirmed_bytes(), 7L)
  s.verify_complete(range => payload(data, range))
}

///|
test "cancelled, foreign and restored leases are rejected" {
  let data = b"abc"
  let object = spec(data)
  let s = @moonfetchledger.Session::new(object, chunk_size=3)
  let old = s.reserve_missing().unwrap()
  s.release(old)
  let new = s.reserve_missing().unwrap()
  rejects(() => commit(s, old, data))
  let other = @moonfetchledger.Session::new(object, chunk_size=3)
  rejects(() => commit(other, new, data))
  commit(s, new, data)
  let restored = @moonfetchledger.restore(s.checkpoint(), object)
  rejects(() => commit(restored, new, data))
  assert_eq(restored.confirmed_bytes(), 0L)
}

///|
test "bad HTTP responses leave coverage unchanged and allow retry" {
  let data = b"abc"
  let s = @moonfetchledger.Session::new(spec(data), chunk_size=3)
  let lease = s.reserve_missing().unwrap()
  let before = s.checkpoint()
  for status in [200, 404, 416] {
    rejects(() => {
      ignore(
        s.prepare_chunk(
          lease,
          data,
          status~,
          etag="\"v1\"",
          range=lease.range,
          total=3L,
        ),
      )
    })
  }
  rejects(() => {
    ignore(
      s.prepare_chunk(
        lease,
        data,
        status=206,
        etag="\"v2\"",
        range=lease.range,
        total=3L,
      ),
    )
  })
  rejects(() => {
    ignore(
      s.prepare_chunk(
        lease,
        data,
        status=206,
        etag="\"v1\"",
        range=lease.range,
        total=4L,
      ),
    )
  })
  rejects(() => {
    ignore(
      s.prepare_chunk(
        lease,
        data,
        status=206,
        etag="\"v1\"",
        range=lease.range,
        total=3L,
        content_encoding="gzip",
      ),
    )
  })
  rejects(() => {
    ignore(
      s.prepare_chunk(
        lease,
        b"ab",
        status=206,
        etag="\"v1\"",
        range=lease.range,
        total=3L,
      ),
    )
  })
  rejects(() => {
    ignore(
      s.prepare_chunk(
        lease,
        data,
        status=206,
        etag="\"v1\"",
        range={ start: 1L, end: 4L, },
        total=3L,
      ),
    )
  })
  assert_eq(s.checkpoint(), before)
  commit(s, lease, data)
  s.verify_complete(range => payload(data, range))
}

///|
test "failed readback cannot advance progress or overwrite a confirmed digest" {
  let data = b"abc"
  let s = @moonfetchledger.Session::new(spec(data), chunk_size=3)
  let lease = s.reserve_missing().unwrap()
  let p = s.prepare_chunk(
    lease,
    data,
    status=206,
    etag="\"v1\"",
    range=lease.range,
    total=3L,
  )
  rejects(() => s.commit_written(p, b"abd"))
  rejects(() => s.commit_written(p, b"ab"))
  assert_eq(s.confirmed_bytes(), 0L)
  s.commit_written(p, data)
  let before = s.checkpoint()
  rejects(() => {
    ignore(
      s.prepare_chunk(
        lease,
        b"abd",
        status=206,
        etag="\"v1\"",
        range=lease.range,
        total=3L,
      ),
    )
  })
  rejects(() => s.release(lease))
  assert_eq(s.checkpoint(), before)
}

///|
test "restore requires actual storage and detects corrupted and missing blocks" {
  let data = b"abcdefghi"
  let object = spec(data)
  let s = @moonfetchledger.Session::new(object, chunk_size=3)
  while s.reserve_missing() is Some(lease) {
    commit(s, lease, data)
  }
  let checkpoint = s.checkpoint()
  let r = @moonfetchledger.restore(checkpoint, object)
  rejects(() => ignore(r.reserve_missing()))
  rejects(() => r.verify_complete(range => payload(data, range)))
  rejects(() => r.finish_recovery())
  let ranges = r.recovery_ranges()
  assert_true(r.reconcile_block(ranges[0], Some(b"abc")))
  assert_true(!r.reconcile_block(ranges[1], Some(b"dxf")))
  assert_true(!r.reconcile_block(ranges[2], None))
  r.finish_recovery()
  assert_eq(r.confirmed_bytes(), 3L)
  while r.reserve_missing() is Some(lease) {
    commit(r, lease, data)
  }
  assert_eq(r.checkpoint(), checkpoint)
  r.verify_complete(range => payload(data, range))
}

///|
test "restoration discards outstanding reservations without losing confirmed bytes" {
  let data = b"abcdef"
  let object = spec(data)
  let s = @moonfetchledger.Session::new(object, chunk_size=3)
  let committed = s.reserve_missing().unwrap()
  let pending = s.reserve_missing().unwrap()
  commit(s, committed, data)
  let r = @moonfetchledger.restore(s.checkpoint(), object)
  for range in r.recovery_ranges() {
    ignore(r.reconcile_block(range, Some(payload(data, range))))
  }
  r.finish_recovery()
  assert_eq(r.reserve_missing().unwrap().range, pending.range)
}

///|
test "strict checkpoint rejects unknown data rather than dropping it" {
  let object = spec(b"abc")
  let s = @moonfetchledger.Session::new(object, chunk_size=3)
  commit(s, s.reserve_missing().unwrap(), b"abc")
  let good = s.checkpoint()
  for
    bad in [
      "",
      "null",
      "{}",
      "{\"x\":1,\"x\":2}",
      good[:good.length() - 1].to_owned(),
      good.replace(old="MFL1", new="MFL2"),
      good.replace(old="\"3\"", new="\"03\""),
      good.replace(old="\"3\"", new="\"9223372036854775808\""),
      good.replace(old="\"0\"", new="\"1\""),
      good[:good.length() - 1].to_owned() + ",null]",
    ] {
    rejects(() => ignore(@moonfetchledger.restore(bad, object)))
  }
  let changed = @moonfetchledger.ObjectSpec::new(
    object.resource,
    3L,
    "\"v2\"",
    object.sha256,
  )
  rejects(() => ignore(@moonfetchledger.restore(good, changed)))
  let r = @moonfetchledger.restore(good, object)
  rejects(() => ignore(r.checkpoint()))
  for range in r.recovery_ranges() {
    ignore(r.reconcile_block(range, Some(b"abc")))
  }
  r.finish_recovery()
  assert_eq(r.checkpoint(), good)
}

///|
test "every-prefix truncation of a valid checkpoint is rejected" {
  let object = spec(b"abc")
  let s = @moonfetchledger.Session::new(object)
  let text = s.checkpoint()
  for i in 0..<text.length() {
    rejects(() => ignore(@moonfetchledger.restore(text[:i].to_owned(), object)))
  }
}

///|
test "object and arithmetic boundaries fail explicitly" {
  let hash = @moonfetchledger.digest(b"")
  for etag in ["", "v1", "W/\"v1\"", "\"a\nb\"", "\"a\"b\""] {
    rejects(() => ignore(@moonfetchledger.ObjectSpec::new("x", 0L, etag, hash)))
  }
  rejects(() => ignore(@moonfetchledger.ObjectSpec::new("", 0L, "\"a\"", hash)))
  rejects(() => {
    ignore(@moonfetchledger.ObjectSpec::new("x", -1L, "\"a\"", hash))
  })
  rejects(() => {
    ignore(@moonfetchledger.ObjectSpec::new("x", 0L, "\"a\"", "bad"))
  })
  let huge = @moonfetchledger.ObjectSpec::new(
    "x", 9223372036854775807L, "\"a\"", hash,
  )
  rejects(() => ignore(@moonfetchledger.Session::new(huge)))
  for size in [0, -1, 4194305] {
    rejects(() => {
      ignore(@moonfetchledger.Session::new(spec(b""), chunk_size=size))
    })
  }
  let boundary = @moonfetchledger.Session::new(
    @moonfetchledger.ObjectSpec::new("x", 100000L, "\"a\"", hash),
    chunk_size=1,
  )
  assert_eq(boundary.reserve_missing().unwrap().range.end, 1L)
  rejects(() => {
    ignore(
      @moonfetchledger.Session::new(
        @moonfetchledger.ObjectSpec::new("x", 100001L, "\"a\"", hash),
        chunk_size=1,
      ),
    )
  })
}

///|
test "empty object verifies and round trips without HTTP ranges" {
  let object = spec(b"")
  let s = @moonfetchledger.Session::new(object)
  assert_true(s.reserve_missing() is None)
  s.verify_complete(_ => b"")
  let r = @moonfetchledger.restore(s.checkpoint(), object)
  r.finish_recovery()
  r.verify_complete(_ => b"")
  assert_eq(r.checkpoint(), s.checkpoint())
}

///|
test "complete coverage still requires whole-file digest and storage reads" {
  let data = b"abc"
  let s = @moonfetchledger.Session::new(spec(data), chunk_size=3)
  rejects(() => s.verify_complete(_ => data))
  commit(s, s.reserve_missing().unwrap(), data)
  rejects(() => s.verify_complete(_ => b"abd"))
  rejects(() => s.verify_complete(_ => b"ab"))
  rejects(() => s.verify_complete(_ => fail("simulated storage fault")))
  s.verify_complete(_ => data)
  let verifier = s.verifier()
  rejects(() => verifier.finish())
  rejects(() => verifier.push(b"ab"))
  verifier.push(data)
  verifier.finish()
  verifier.finish()
  rejects(() => verifier.push(data))
}

///|
test "generated binary payloads, chunk boundaries and deterministic round trips" {
  for length in 0..<129 {
    let data = Bytes::makei(length, i => ((i * 67 + length) % 256).to_byte())
    let object = spec(data)
    for size in [1, 3, 16, 31] {
      let s = @moonfetchledger.Session::new(object, chunk_size=size)
      let leases = []
      while s.reserve_missing() is Some(lease) {
        leases.push(lease)
      }
      for i in 0..<leases.length() {
        commit(s, leases[leases.length() - 1 - i], data)
      }
      s.verify_complete(range => payload(data, range))
      let saved = s.checkpoint()
      let r = @moonfetchledger.restore(saved, object)
      for range in r.recovery_ranges() {
        assert_true(r.reconcile_block(range, Some(payload(data, range))))
      }
      r.finish_recovery()
      r.verify_complete(range => payload(data, range))
      assert_eq(r.checkpoint(), saved)
    }
  }
}
