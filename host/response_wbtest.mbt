///|
test "strict response Content-Range and inclusive overflow boundaries" {
  let (range, total) = content_range("bytes 3-4/5")
  assert_eq(range, { start: 3L, end: 5L, })
  assert_eq(total, 5L)
  let (large, _) = content_range(
    "bytes 9223372036854775806-9223372036854775806/9223372036854775807",
  )
  assert_eq(large.end, 9223372036854775807L)
  for
    bad in [
      "", "items 0-1/2", "bytes */3", "bytes 0-0/*", "bytes 01-2/3", "bytes 0-3/3",
      "bytes 2-1/3", "bytes -1-2/3", "bytes 0-1/2/3", "bytes 0-1-2/3", "bytes 0-1/02",
      "bytes 0-1/9223372036854775808", "bytes 0-1/2,3-4/5", "bytes 0-1/2 ",
    ] {
    try content_range(bad) catch {
      InvalidResponse(_) => ()
      _ => fail("incorrect response diagnostic")
    } noraise {
      _ => fail("accepted malformed Content-Range: \{bad}")
    }
  }
}
