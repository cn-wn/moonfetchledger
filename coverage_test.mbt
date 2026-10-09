///|
test "coverage projection partitions every confirmation mask without mutation" {
  let data = b"abcdefghijklmnopqrs"
  for mask in 0..<128 {
    let s = @moonfetchledger.Session::new(spec(data), chunk_size=3)
    let mut expected = 0L
    for index in 0..<7 {
      let lease = s.reserve_missing().unwrap()
      if (mask & (1 << index)) != 0 {
        commit(s, lease, data)
        expected += lease.range.length()
      }
    }
    let checkpoint = s.checkpoint()
    let gaps = s.unconfirmed_ranges()
    assert_eq(s.unconfirmed_ranges(), gaps)
    assert_eq(s.checkpoint(), checkpoint)
    assert_eq(s.confirmed_bytes(), expected)
    let mut gap_bytes = 0L
    let mut last_end = -1L
    for range in gaps {
      assert_true(range.start > last_end)
      assert_true(
        range.start >= 0L && range.start < range.end && range.end <= 19L,
      )
      last_end = range.end
      gap_bytes += range.length()
    }
    assert_eq(gap_bytes + expected, 19L)
    for offset in 0..<19 {
      let covered = (mask & (1 << (offset / 3))) != 0
      let in_gap = gaps.any(r => {
        r.start <= offset.to_int64() && offset.to_int64() < r.end
      })
      assert_eq(in_gap, !covered)
    }
    gaps.clear()
    assert_eq(s.unconfirmed_ranges().is_empty(), mask == 127)
  }
}

///|
test "coverage recovery gate, cancellation, empty and maximum supported length" {
  let data = b"abcdefg"
  let s = @moonfetchledger.Session::new(spec(data), chunk_size=3)
  let first = s.reserve_missing().unwrap()
  let second = s.reserve_missing().unwrap()
  commit(s, first, data)
  let gaps = s.unconfirmed_ranges()
  assert_eq(gaps, [{ start: 3L, end: 7L, }])
  s.release(second)
  assert_eq(s.unconfirmed_ranges(), gaps)
  let restored = @moonfetchledger.restore(s.checkpoint(), spec(data))
  try restored.unconfirmed_ranges() catch {
    @moonfetchledger.RecoveryRequired => ()
    _ => fail("incorrect unreconciled coverage diagnostic")
  } noraise {
    _ => fail("trusted restored coverage before readback")
  }
  assert_true(restored.reconcile_block(first.range, None) == false)
  restored.finish_recovery()
  assert_eq(restored.unconfirmed_ranges(), [{ start: 0L, end: 7L, }])
  let empty = @moonfetchledger.Session::new(spec(b""))
  assert_true(empty.unconfirmed_ranges().is_empty())
  let large = @moonfetchledger.ObjectSpec::new(
    "https://example.test/large",
    419430400000L,
    "\"v1\"",
    @moonfetchledger.digest(b""),
  )
  let maximum = @moonfetchledger.Session::new(large, chunk_size=4194304)
  assert_eq(maximum.unconfirmed_ranges(), [{ start: 0L, end: 419430400000L, }])
}
