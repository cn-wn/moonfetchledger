///|
/// File fixture or caller-selected path is assembled through the public API.
async fn main {
  let args = @env.args()
  let mut path = "fixtures/earthquakes-2024-01-01.csv"
  for i in 0..<args.length() {
    if args[i] == "--input" {
      if i + 1 >= args.length() {
        fail("--input requires a file path")
      }
      path = args[i + 1]
    }
  }
  let data = @fs.read_file(path).binary()
  let object = @ledger.ObjectSpec::new(
    path,
    data.length().to_int64(),
    "\"fixture-v1\"",
    @ledger.digest(data),
  )
  let session = @ledger.Session::new(object, chunk_size=4096)
  let leases = []
  while session.reserve_missing() is Some(lease) {
    leases.push(lease)
  }
  let storage = FixedArray::make(data.length(), b'\x00')
  for i in 0..<leases.length() {
    let lease = leases[leases.length() - 1 - i]
    let range = lease.range
    let bytes = data[range.start.to_int():range.end.to_int()].to_owned()
    let prepared = session.prepare_chunk(
      lease,
      bytes,
      status=206,
      etag=object.etag,
      range~,
      total=object.length,
    )
    for j, byte in bytes {
      storage[range.start.to_int() + j] = byte
    }
    session.commit_written(
      prepared,
      Bytes::from_array(storage[range.start.to_int():range.end.to_int()]),
    )
  }
  let checkpoint = session.checkpoint()
  let restored = @ledger.restore(checkpoint, object)
  if !data.is_empty() {
    storage[0] = (storage[0].to_int() ^ 1).to_byte()
  }
  let mut invalidated = 0
  for range in restored.recovery_ranges() {
    if !restored.reconcile_block(
        range,
        Some(
          Bytes::from_array(storage[range.start.to_int():range.end.to_int()]),
        ),
      ) {
      invalidated += 1
    }
  }
  restored.finish_recovery()
  while restored.reserve_missing() is Some(lease) {
    let range = lease.range
    let bytes = data[range.start.to_int():range.end.to_int()].to_owned()
    let prepared = restored.prepare_chunk(
      lease,
      bytes,
      status=206,
      etag=object.etag,
      range~,
      total=object.length,
    )
    for j, byte in bytes {
      storage[range.start.to_int() + j] = byte
    }
    restored.commit_written(
      prepared,
      Bytes::from_array(storage[range.start.to_int():range.end.to_int()]),
    )
  }
  restored.verify_complete(range => {
    Bytes::from_array(storage[range.start.to_int():range.end.to_int()])
  })
  println(
    "verified \{restored.confirmed_bytes()} bytes; invalidated \{invalidated} block; sha256=\{object.sha256}",
  )
}
