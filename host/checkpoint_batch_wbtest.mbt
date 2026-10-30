///|
async test "small-block batching reduces installed checkpoints with identical final bytes and metadata" {
  let dir = @fs.tmpdir(prefix="mfl-batch-scale-")
  defer @fs.rmdir(dir, recursive=true)
  let data = Bytes::makei(2049, i => (i % 251).to_byte())
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/data",
    data.length().to_int64(),
    "\"v1\"",
    @ledger.digest(data),
  )
  let checkpoints : Array[String] = []
  let bytes_written : Array[Int64] = []
  for limit in [1, 64] {
    let output = dir + "/" + limit.to_string()
    let session = @ledger.Session::new(spec, chunk_size=2)
    let file = @fs.open(output, mode=ReadWrite, create_mode=CreateNew)
    defer file.close()
    let batch = CheckpointBatch::new(session, file, output + ".mfl", limit)
    let mut groups = 0
    let mut metadata_bytes = 0L
    while session.reserve_missing() is Some(lease) {
      let range = lease.range
      let block = data[range.start.to_int():range.end.to_int()].to_owned()
      let prepared = session.prepare_chunk(
        lease,
        block,
        status=206,
        etag=spec.etag,
        range~,
        total=spec.length,
      )
      if !batch.append(prepared, range, block).is_empty() {
        groups += 1
        metadata_bytes += @fs.read_file(output + ".mfl")
          .binary()
          .length()
          .to_int64()
      }
    }
    if !batch.flush().is_empty() {
      groups += 1
      metadata_bytes += @fs.read_file(output + ".mfl")
        .binary()
        .length()
        .to_int64()
    }
    assert_eq(groups, if limit == 1 { 1025 } else { 17 })
    assert_eq(session.confirmed_bytes(), spec.length)
    assert_eq(@fs.read_file(output).binary(), data)
    checkpoints.push(@fs.read_file(output + ".mfl").text())
    bytes_written.push(metadata_bytes)
  }
  assert_eq(checkpoints[0], checkpoints[1])
  assert_true(bytes_written[1] * 20L < bytes_written[0])
}

///|
async test "unflushed writes never enter saved coverage and corrupt readback refuses a batch" {
  let dir = @fs.tmpdir(prefix="mfl-batch-readback-")
  defer @fs.rmdir(dir, recursive=true)
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/data",
    6L,
    "\"v1\"",
    @ledger.digest(b"abcdef"),
  )
  let output = dir + "/out"
  let session = @ledger.Session::new(spec, chunk_size=3)
  save(session, output + ".mfl")
  let original = @fs.read_file(output + ".mfl").text()
  let file = @fs.open(output, mode=ReadWrite, create_mode=CreateNew)
  defer file.close()
  let batch = CheckpointBatch::new(session, file, output + ".mfl", 3)
  let lease = session.reserve_missing().unwrap()
  let prepared = session.prepare_chunk(
    lease,
    b"abc",
    status=206,
    etag=spec.etag,
    range=lease.range,
    total=6L,
  )
  assert_true(batch.append(prepared, lease.range, b"abc").is_empty())
  assert_eq(session.confirmed_bytes(), 0L)
  assert_eq(@fs.read_file(output + ".mfl").text(), original)
  file.write_at(b"!", position=0L)
  try batch.flush() catch {
    @ledger.ReadbackMismatch(_) => ()
    _ => fail("batch did not retain readback diagnostic")
  } noraise {
    _ => fail("batch accepted damaged bytes")
  }
  assert_eq(@fs.read_file(output + ".mfl").text(), original)
}
