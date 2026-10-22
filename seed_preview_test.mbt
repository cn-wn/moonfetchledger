///|
test "preview partitions target bytes deterministically including short empty and duplicate blocks" {
  for data in [b"", b"abc", b"abcDEFabc!", b"0123456789"] {
    for width in [1, 3, 7] {
      let reference = delta_index(data, width)
      for seed in [b"", b"unrelated", b"xx!yyDEF--abc", data] {
        let plan = scanned(reference, seed, 1)
        assert_eq(plan.to_json(), scanned(reference, seed, 65536).to_json())
        assert_eq(
          plan.download_bytes() + plan.reused_bytes,
          data.length().to_int64(),
        )
        let hits = Array::make(data.length(), 0)
        for m in plan.matches() {
          for i in m.target.start.to_int()..<m.target.end.to_int() {
            hits[i] += 1
          }
        }
        for gap in plan.missing_ranges() {
          for i in gap.start.to_int()..<gap.end.to_int() {
            hits[i] += 1
          }
        }
        assert_true(hits.all(n => n == 1))
        let gaps = plan.missing_ranges()
        gaps.clear()
        assert_eq(
          plan.download_bytes(),
          plan.missing_ranges().fold(init=0L, (n, r) => n + r.length()),
        )
        assert_eq(@json.parse(plan.to_json().stringify()), plan.to_json())
      }
    }
  }
}
