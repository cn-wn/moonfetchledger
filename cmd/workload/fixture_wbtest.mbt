///|
test "synthetic generator is reproducible across segmentation and has a fixed byte sequence" {
  let a : Generator = { state: 1U, }
  assert_eq(a.take(4), b"\x00\x04\x9d\x12")
  let b : Generator = { state: 1U, }
  assert_eq(b.take(0), b"")
  assert_eq(b.take(4), b"\x00\x04\x9d\x12")
  let c : Generator = { state: 0x9E3779B9U, }
  let d : Generator = { state: 0x9E3779B9U, }
  assert_eq(c.take(257), d.take(1) + d.take(2) + d.take(17) + d.take(237))
}
