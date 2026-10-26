///|
test "a blocked byte may be replaced without consuming stale probe state" {
  let reference = delta_index(b"abcc", 3)
  let scanner = reference.scanner()
  let stopped = scanner.push_bounded(b"abc", max_hash_bytes=0L)
  assert_true(stopped.blocked)
  assert_eq(stopped.consumed_bytes, 2)
  try scanner.push_bounded(b"c", max_hash_bytes=-1L) catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong invalid-budget diagnostic")
  } noraise {
    _ => fail("accepted negative budget after blocked input")
  }
  assert_eq(scanner.push_bounded(b"xabc", max_hash_bytes=64L).consumed_bytes, 4)
  let actual = scanner.finish()
  let expected = scanned(reference, b"abxabc", 1)
  assert_eq(actual.to_json(), expected.to_json())
  assert_eq(actual.hashed_bytes, expected.hashed_bytes)
  assert_eq(actual.matches()[0].source.start, 3L)
}

///|
test "budgeted weak probes preserve first matches and exact charging across window and call boundaries" {
  let source = Bytes::makei(257, i => ((i * 37 + 11) % 256).to_byte())
  let target = source[59:167].to_owned() + source[:3].to_owned()
  let seed = b"\x00prefix|" + source + source[40:220].to_owned()
  for width in [1, 3, 7, 13, 64] {
    let reference = delta_index(target, width)
    let expected = scanned(reference, seed, 65536)
    for stride in [1, 5, 65] {
      let scanner = reference.scanner()
      let mut offset = 0
      let mut calls = 0
      let mut charged = 0L
      while offset < seed.length() {
        let end = (offset + stride).min(seed.length())
        let budget = [0L, 1L, 17L, 256L][calls % 4]
        let step = scanner.push_bounded(
          seed[offset:end].to_owned(),
          max_hash_bytes=budget,
        )
        assert_true(step.hashed_bytes <= budget)
        assert_true(step.consumed_bytes <= end - offset)
        if step.blocked {
          assert_true(step.consumed_bytes < end - offset)
        }
        offset += step.consumed_bytes
        charged += step.hashed_bytes
        calls += 1
        assert_true(calls < 20000)
      }
      let plan = scanner.finish()
      assert_eq(plan.to_json(), expected.to_json())
      assert_eq(plan.hashed_bytes, expected.hashed_bytes)
      assert_eq(plan.hashed_bytes, charged)
    }
  }
}
