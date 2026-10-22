///|
pub(all) struct SeedSourceMatch {
  seed_index : Int32
  source : ByteRange
  target : ByteRange
} derive(Eq, Debug)

///|
pub extend SeedSourceMatch with Eq::{equal, not_equal}

///|
pub extend SeedSourceMatch with Debug::{to_repr}

///|
/// Collect up to 32 independently scanned seeds. First seed wins each block.
pub struct SeedPool {
  priv reference : DeltaReference
  priv selected : Array[SeedSourceMatch?]
  priv counts : Array[Int64]
  priv mut scanned : Int64
  priv mut hashed : Int64
  priv mut closed : Bool
}

///|
pub fn SeedPool::new(reference : DeltaReference) -> SeedPool {
  {
    reference,
    selected: Array::make(reference.strong.length(), None),
    counts: [],
    scanned: 0L,
    hashed: 0L,
    closed: false,
  }
}

///|
/// Identity/layout errors and the input limit fail before modifying the pool.
pub fn SeedPool::add(
  self : SeedPool,
  plan : SeedPlan,
) -> Unit raise LedgerError {
  if self.closed ||
    self.counts.length() >= 32 ||
    plan.spec != self.reference.spec ||
    plan.chunk_size != self.reference.chunk_size ||
    self.scanned > 9223372036854775807L - plan.scanned_bytes ||
    self.hashed > 9223372036854775807L - plan.hashed_bytes {
    raise InvalidSpec(
      "seed pool requires open state, at most 32 seeds, identical target/layout and bounded scanned bytes",
    )
  }
  let index = self.counts.length()
  let mut bytes = 0L
  for record in plan.records {
    let block = (record.target.start / self.reference.chunk_size.to_int64()).to_int()
    if self.selected[block] is None {
      self.selected[block] = Some({
        seed_index: index,
        source: record.source,
        target: record.target,
      })
      bytes += record.target.length()
    }
  }
  self.counts.push(bytes)
  self.scanned += plan.scanned_bytes
  self.hashed += plan.hashed_bytes
}

///|
pub struct SeedPoolPlan {
  scanned_bytes : Int64
  reused_bytes : Int64
  hashed_bytes : Int64
  priv spec : ObjectSpec
  priv records : Array[SeedSourceMatch]
  priv counts : Array[Int64]
}

///|
/// Idempotent immutable snapshot; an empty pool is refused.
pub fn SeedPool::finish(self : SeedPool) -> SeedPoolPlan raise LedgerError {
  if self.counts.is_empty() {
    raise InvalidSpec("seed pool requires at least one seed")
  }
  self.closed = true
  let records = []
  for match_ in self.selected {
    if match_ is Some(record) {
      records.push(record)
    }
  }
  {
    scanned_bytes: self.scanned,
    hashed_bytes: self.hashed,
    reused_bytes: self.counts.fold(init=0L, (n, v) => n + v),
    spec: self.reference.spec,
    records,
    counts: self.counts.copy(),
  }
}

///|
pub fn SeedPoolPlan::matches(self : SeedPoolPlan) -> Array[SeedSourceMatch] {
  self.records.copy()
}

///|
pub fn SeedPoolPlan::per_seed_reused_bytes(self : SeedPoolPlan) -> Array[Int64] {
  self.counts.copy()
}

///|
pub fn SeedPoolPlan::missing_ranges(self : SeedPoolPlan) -> Array[ByteRange] {
  target_gaps(self.spec.length, self.records.iter().map(r => r.target))
}

///|
pub fn SeedPoolPlan::download_bytes(self : SeedPoolPlan) -> Int64 {
  self.spec.length - self.reused_bytes
}

///|
pub fn SeedPoolPlan::to_json(self : SeedPoolPlan) -> Json {
  Json::array([
    Json::string("MFLPOOL1"),
    Json::string(self.spec.length.to_string()),
    Json::string(self.scanned_bytes.to_string()),
    Json::string(self.reused_bytes.to_string()),
    Json::string(self.download_bytes().to_string()),
    Json::array(self.counts.map(v => Json::string(v.to_string()))),
    Json::array(
      self.records.map(r => {
        Json::array([
          Json::string(r.seed_index.to_string()),
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
