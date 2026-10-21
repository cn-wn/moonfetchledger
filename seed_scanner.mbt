///|
/// Byte ranges in ONE untrusted seed and the authenticated target. Target ranges
/// are whole aligned target blocks; source ranges may begin at any byte offset.
pub(all) struct SeedMatch {
  source : ByteRange
  target : ByteRange
} derive(Eq, Debug)

///|
pub extend SeedMatch with Eq::{equal, not_equal}

///|
pub extend SeedMatch with Debug::{to_repr}

///|
pub struct SeedPlan {
  scanned_bytes : Int64
  reused_bytes : Int64
  priv records : Array[SeedMatch]
}

///|
/// Fresh snapshot, sorted by target offset. First matching seed offset wins;
/// duplicate target blocks may reuse the same source bytes.
pub fn SeedPlan::matches(self : SeedPlan) -> Array[SeedMatch] {
  self.records.copy()
}

///|
priv struct SeedWindow {
  width : Int32
  ring : FixedArray[Byte]
  buckets : Map[UInt32, Map[String, Array[Int32]]]
  mut head : Int32
  mut count : Int32
  mut a : UInt32
  mut b : UInt32
}

///|
/// Streaming, bounded to two target-sized windows plus O(target block count).
/// Splitting input at arbitrary boundaries does not change the plan.
pub struct SeedScanner {
  priv reference : DeltaReference
  priv windows : Array[SeedWindow]
  priv offsets : Array[Int64?]
  priv mut position : Int64
  priv mut closed : Bool
}

///|
pub fn DeltaReference::scanner(self : DeltaReference) -> SeedScanner {
  let windows : Array[SeedWindow] = []
  for i, hash in self.strong {
    let width = (self.spec.length - i.to_int64() * self.chunk_size.to_int64())
      .min(self.chunk_size.to_int64())
      .to_int()
    let window = match windows.iter().find_first(w => w.width == width) {
      Some(w) => w
      None => {
        let w : SeedWindow = {
          width,
          ring: FixedArray::make(width, b'\x00'),
          buckets: Map([]),
          head: 0,
          count: 0,
          a: 0U,
          b: 0U,
        }
        windows.push(w)
        w
      }
    }
    let bucket = match window.buckets.get(self.weak[i]) {
      Some(bucket) => bucket
      None => {
        let bucket = Map([])
        window.buckets[self.weak[i]] = bucket
        bucket
      }
    }
    match bucket.get(hash) {
      Some(indices) => indices.push(i)
      None => bucket[hash] = [i]
    }
  }
  {
    reference: self,
    windows,
    offsets: Array::make(self.strong.length(), None),
    position: 0L,
    closed: false,
  }
}

///|
pub fn SeedScanner::push(
  self : SeedScanner,
  bytes : Bytes,
) -> Unit raise LedgerError {
  if self.closed ||
    self.position > 9223372036854775807L - bytes.length().to_int64() {
    raise InvalidSpec("seed scanner is finished or seed position exceeds Int64")
  }
  for byte in bytes {
    self.position += 1L
    for window in self.windows {
      if window.buckets.is_empty() {
        continue
      }
      let incoming = byte.to_int().reinterpret_as_uint()
      if window.count < window.width {
        window.ring[window.count] = byte
        window.count += 1
        window.a = (window.a + incoming) & 65535U
        window.b = (window.b + window.a) & 65535U
      } else {
        let outgoing = window.ring[window.head].to_int().reinterpret_as_uint()
        window.ring[window.head] = byte
        window.head = (window.head + 1) % window.width
        window.a = (window.a - outgoing + incoming) & 65535U
        window.b = (
            window.b - window.width.reinterpret_as_uint() * outgoing + window.a
          ) &
          65535U
      }
      if window.count == window.width {
        let weak = (window.b << 16) | window.a
        if window.buckets.get(weak) is Some(bucket) {
          let hash = digest(
            Bytes::makei(window.width, i => {
              window.ring[(window.head + i) % window.width]
            }),
          )
          if bucket.get(hash) is Some(indices) {
            for index in indices {
              self.offsets[index] = Some(
                self.position - window.width.to_int64(),
              )
            }
            bucket.remove(hash)
            if bucket.is_empty() {
              window.buckets.remove(weak)
            }
          }
        }
      }
    }
  }
}

///|
/// Idempotent. Subsequent push calls are rejected without changing this result.
pub fn SeedScanner::finish(self : SeedScanner) -> SeedPlan {
  self.closed = true
  let records = []
  let mut reused = 0L
  for i, offset in self.offsets {
    if offset is Some(start) {
      let target_start = i.to_int64() * self.reference.chunk_size.to_int64()
      let length = (self.reference.spec.length - target_start).min(
        self.reference.chunk_size.to_int64(),
      )
      records.push({
        source: { start, end: start + length, },
        target: { start: target_start, end: target_start + length, },
      })
      reused += length
    }
  }
  { scanned_bytes: self.position, reused_bytes: reused, records, }
}
