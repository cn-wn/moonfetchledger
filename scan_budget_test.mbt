///|
test "bounded scanner stops before both windows consume a byte and resumes its exact suffix" {
  let reference = delta_index(b"abcc", 3)
  let scanner = reference.scanner()
  try scanner.push_bounded(b"abc", max_hash_bytes=-1L) catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong negative work budget")
  } noraise {
    _ => fail("negative work budget accepted")
  }
  let first = scanner.push_bounded(b"abc", max_hash_bytes=3L)
  assert_true(first.blocked)
  assert_eq(first.consumed_bytes, 2)
  assert_eq(first.hashed_bytes, 0L)
  let blocked = scanner.push_bounded(b"c", max_hash_bytes=3L)
  assert_true(blocked.blocked)
  assert_eq(blocked.consumed_bytes, 0)
  let last = scanner.push_bounded(b"c", max_hash_bytes=4L)
  assert_true(!last.blocked)
  assert_eq(last.consumed_bytes, 1)
  assert_eq(last.hashed_bytes, 4L)
  let plan = scanner.finish()
  assert_eq(plan.scanned_bytes, 3L)
  assert_eq(plan.reused_bytes, 4L)
  assert_eq(plan.hashed_bytes, 4L)
  assert_eq(plan.to_json(), scanned(reference, b"abc", 65536).to_json())
  try scanner.push_bounded(b"", max_hash_bytes=0L) catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong finished scanner error")
  } noraise {
    _ => fail("finished scanner accepted budgeted input")
  }
  let prefix = reference.scanner()
  assert_true(prefix.push_bounded(b"abc", max_hash_bytes=0L).blocked)
  assert_eq(prefix.finish().scanned_bytes, 2L)
  assert_eq(prefix.finish().reused_bytes, 0L)
}

///|
test "weak collisions charge failed SHA candidates and bounded chunking preserves unbounded output" {
  let target = b"\x0a\x14\x1e"
  let reference = delta_index(target, 3)
  let bytes = Buffer()
  for _ in 0..<32 {
    bytes.write_bytes(b"\x0b\x12\x1f")
  }
  bytes.write_bytes(target)
  let seed = bytes.to_bytes()
  let oracle = scanned(reference, seed, 65536)
  assert_eq(oracle.hashed_bytes, 99L)
  assert_eq(oracle.matches()[0].source.start, 96L)
  for stride in [1, 2, 7, 65536] {
    let scanner = reference.scanner()
    let mut offset = 0
    let mut charged = 0L
    while offset < seed.length() {
      let end = (offset + stride).min(seed.length())
      let step = scanner.push_bounded(
        seed[offset:end].to_owned(),
        max_hash_bytes=3L,
      )
      assert_true(step.consumed_bytes > 0)
      assert_true(step.hashed_bytes <= 3L)
      offset += step.consumed_bytes
      charged += step.hashed_bytes
    }
    let result = scanner.finish()
    assert_eq(result.hashed_bytes, charged)
    assert_eq(result.hashed_bytes, oracle.hashed_bytes)
    assert_eq(result.to_json(), oracle.to_json())
  }
  let no_hit = reference.scanner()
  let step = no_hit.push_bounded(b"unrelated", max_hash_bytes=0L)
  assert_true(!step.blocked)
  assert_eq(step.hashed_bytes, 0L)
  assert_eq(no_hit.finish().download_bytes(), 3L)
}
