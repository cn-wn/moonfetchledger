///|
/// Coalesced complement of verified reusable target blocks. Fresh snapshot.
pub fn SeedPlan::missing_ranges(self : SeedPlan) -> Array[ByteRange] {
  target_gaps(self.spec.length, self.records.iter().map(r => r.target))
}

///|
fn target_gaps(length : Int64, ranges : Iter[ByteRange]) -> Array[ByteRange] {
  let gaps = []
  let mut cursor = 0L
  for range in ranges {
    if cursor < range.start {
      gaps.push({ start: cursor, end: range.start, })
    }
    cursor = range.end
  }
  if cursor < length {
    gaps.push({ start: cursor, end: length, })
  }
  gaps
}

///|
/// Logical bytes not found in this seed, excluding HTTP overhead and retries.
pub fn SeedPlan::download_bytes(self : SeedPlan) -> Int64 {
  self.spec.length - self.reused_bytes
}

///|
/// Deterministic MFLPLAN1 report. A preview is a snapshot, not write authority.
pub fn SeedPlan::to_json(self : SeedPlan) -> Json {
  Json::array([
    Json::string("MFLPLAN1"),
    Json::string(self.spec.length.to_string()),
    Json::string(self.scanned_bytes.to_string()),
    Json::string(self.reused_bytes.to_string()),
    Json::string(self.download_bytes().to_string()),
    Json::array(
      self.records.map(r => {
        Json::array([
          Json::string(r.source.start.to_string()),
          Json::string(r.source.end.to_string()),
          Json::string(r.target.start.to_string()),
          Json::string(r.target.end.to_string()),
        ])
      }),
    ),
    Json::array(
      self
      .missing_ranges()
      .map(r => {
        Json::array([
          Json::string(r.start.to_string()),
          Json::string(r.end.to_string()),
        ])
      }),
    ),
  ])
}
