///|
fn masked_seed(data : Bytes, mask : Int32) -> Bytes {
  let bytes = Buffer()
  for i in 0..<4 {
    if (mask & (1 << i)) != 0 {
      bytes.write_bytes(b"xx")
      bytes.write_bytes(data[i * 3:(i * 3 + 3).min(data.length())])
      bytes.write_bytes(b"yy")
    }
  }
  bytes.to_bytes()
}

///|
test "seed pool union matches exhaustive masks with first-source priority and exact partitions" {
  let data = b"abcDEFghi!"
  let reference = delta_index(data, 3)
  for left in 0..<16 {
    for right in 0..<16 {
      let pool = @moonfetchledger.SeedPool::new(reference)
      let a = scanned(reference, masked_seed(data, left), 1)
      let b = scanned(reference, masked_seed(data, right), 2)
      pool.add(a)
      pool.add(b)
      let plan = pool.finish()
      assert_eq(pool.finish().to_json(), plan.to_json())
      let mut expected = 0L
      let mut second = 0L
      for i in 0..<4 {
        if ((left | right) & (1 << i)) != 0 {
          let length = if i == 3 { 1L } else { 3L }
          expected += length
          if (left & (1 << i)) == 0 {
            second += length
          }
        }
      }
      assert_eq(plan.reused_bytes, expected)
      assert_eq(plan.download_bytes() + expected, 10L)
      assert_eq(plan.per_seed_reused_bytes(), [a.reused_bytes, second])
      let covered = Array::make(10, 0)
      for m in plan.matches() {
        for i in m.target.start.to_int()..<m.target.end.to_int() {
          covered[i] += 1
        }
        let index = m.target.start.to_int() / 3
        assert_eq(m.seed_index, if (left & (1 << index)) != 0 { 0 } else { 1 })
      }
      for r in plan.missing_ranges() {
        for i in r.start.to_int()..<r.end.to_int() {
          covered[i] += 1
        }
      }
      assert_true(covered.all(n => n == 1))
      let counts = plan.per_seed_reused_bytes()
      counts.clear()
      let records = plan.matches()
      records.clear()
      assert_eq(plan.per_seed_reused_bytes().length(), 2)
      assert_eq(@json.parse(plan.to_json().stringify()), plan.to_json())
    }
  }
}

///|
test "pool refuses mixed identity layout closed and too many inputs without losing prior matches" {
  let reference = delta_index(b"abcDEF", 3)
  let pool = @moonfetchledger.SeedPool::new(reference)
  try pool.finish() catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong empty pool")
  } noraise {
    _ => fail("empty pool accepted")
  }
  for other in [delta_index(b"other!", 3), delta_index(b"abcDEF", 2)] {
    try pool.add(scanned(other, b"other!abcDEF", 1)) catch {
      @moonfetchledger.InvalidSpec(_) => ()
      _ => fail("wrong mismatched pool")
    } noraise {
      _ => fail("mixed metadata accepted")
    }
  }
  for _ in 0..<32 {
    pool.add(scanned(reference, b"abc", 1))
  }
  try pool.add(scanned(reference, b"DEF", 1)) catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong pool limit")
  } noraise {
    _ => fail("33rd seed accepted")
  }
  let plan = pool.finish()
  assert_eq(plan.reused_bytes, 3L)
  try pool.add(scanned(reference, b"DEF", 1)) catch {
    @moonfetchledger.InvalidSpec(_) => ()
    _ => fail("wrong closed pool")
  } noraise {
    _ => fail("closed pool accepted seed")
  }
  assert_eq(pool.finish().to_json(), plan.to_json())
}
