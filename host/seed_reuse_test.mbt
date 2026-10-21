///|
async fn seed_reference(
  dir : String,
  data : Bytes,
  size : Int32,
) -> @ledger.DeltaReference {
  @fs.write_file(dir + "/publisher", data)
  let pin = @host.write_delta_reference(
    audit_spec(data),
    dir + "/publisher",
    dir + "/delta",
    chunk_size=size,
  )
  @host.load_delta_reference(dir + "/delta", pin)
}

///|
async test "moved seed blocks build a new sparse session and ordinary receive fetches only gaps" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-seed-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEFabcNEW!"
  let reference = seed_reference(dir, data, 3)
  let seed = dir + "/old"
  let output = dir + "/v2"
  let old = b"xx!yyDEF--abc"
  @fs.write_file(seed, old)
  let metadata = @fs.read_file(dir + "/delta").binary()
  let result = @host.reuse_from_seed(reference, seed, output)
  assert_true(!result.complete)
  assert_eq(result.reused_blocks, 4)
  assert_eq(result.reused_bytes, 10L)
  assert_eq(result.missing_ranges, [{ start: 9L, end: 12L, }])
  assert_eq(@host.audit(reference.spec, output).confirmed_bytes, 10L)
  let requested : Array[@ledger.ByteRange] = []
  let completed = @host.receive_from(reference.spec, output, chunk_size=3, fetch_range=r => {
    requested.push(r)
    {
      bytes: data[r.start.to_int():r.end.to_int()].to_owned(),
      status: 206,
      etag: reference.spec.etag,
      range: r,
      total: reference.spec.length,
      content_encoding: "identity",
    }
  })
  assert_true(completed.complete)
  assert_eq(requested, result.missing_ranges)
  assert_eq(completed.downloaded_blocks, 1)
  assert_eq(@fs.read_file(output).binary(), data)
  assert_eq(@fs.read_file(seed).binary(), old)
  assert_eq(@fs.read_file(dir + "/delta").binary(), metadata)
  @host.export_verified(reference.spec, output, dir + "/ready")
  assert_eq(@fs.read_file(dir + "/ready").binary(), data)
}

///|
async test "seed reuse handles empty, no-match, repeated and read-buffer-boundary blocks" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-seed-boundary-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFabc!", 3)
  @fs.write_file(dir + "/seed", Bytes::make(65535, b'x') + b"!DEFabc")
  let report = @host.reuse_from_seed(
    reference,
    dir + "/seed",
    dir + "/complete",
  )
  assert_true(report.complete)
  assert_eq(@fs.read_file(dir + "/complete").binary(), b"abcDEFabc!")
  @fs.write_file(dir + "/none", b"xxxxx")
  let no_match = @host.reuse_from_seed(
    reference,
    dir + "/none",
    dir + "/missing",
  )
  assert_eq(no_match.reused_bytes, 0L)
  assert_eq(no_match.missing_ranges, [{ start: 0L, end: 10L, }])
  assert_eq(@fs.read_file(dir + "/missing").binary(), b"")
  let empty_spec = audit_spec(b"")
  @fs.write_file(dir + "/empty", b"")
  let pin = @host.write_delta_reference(
    empty_spec,
    dir + "/empty",
    dir + "/empty.delta",
    chunk_size=1,
  )
  let empty = @host.load_delta_reference(dir + "/empty.delta", pin)
  assert_true(
    @host.reuse_from_seed(empty, dir + "/none", dir + "/empty.target").complete,
  )
  assert_eq(@fs.read_file(dir + "/empty.target").binary(), b"")
}

///|
async test "seed and publisher errors preserve aliases, unrelated output and metadata then allow retry" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-seed-refusal-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEF"
  let reference = seed_reference(dir, data, 3)
  let seed = dir + "/seed"
  @fs.write_file(seed, b"DEFabc")
  try @host.reuse_from_seed(reference, seed, seed) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong alias error")
  } noraise {
    _ => fail("accepted seed alias")
  }
  for suffix in ["", ".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
    let path = dir + "/target" + suffix
    @fs.write_file(path, b"foreign")
    try @host.reuse_from_seed(reference, seed, dir + "/target") catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong existing-data error")
    } noraise {
      _ => fail("overwrote existing data")
    }
    assert_eq(@fs.read_file(path).binary(), b"foreign")
    assert_eq(@fs.read_file(seed).binary(), b"DEFabc")
    @fs.remove(path)
  }
  let managed_lock = @fs.open(
    seed + ".mfl.lock",
    mode=ReadWrite,
    create_mode=CreateNew,
  )
  assert_true(managed_lock.try_lock(Exclusive))
  try @host.reuse_from_seed(reference, seed, dir + "/target") catch {
    @host.OutputLocked => ()
    _ => fail("wrong seed lock error")
  } noraise {
    _ => fail("ignored seed writer")
  }
  assert_true(!@fs.exists(dir + "/target.mfl.lock"))
  managed_lock.close()
  assert_true(@host.reuse_from_seed(reference, seed, dir + "/target").complete)
  @fs.write_file(dir + "/wrong", b"xxxxxx")
  try
    @host.write_delta_reference(
      reference.spec,
      dir + "/wrong",
      dir + "/bad.delta",
      chunk_size=3,
    )
  catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("wrong publisher error")
  } noraise {
    _ => fail("published wrong file")
  }
  assert_true(!@fs.exists(dir + "/bad.delta"))
  assert_true(!@fs.exists(dir + "/bad.delta.next"))
  @fs.write_file(dir + "/wrong", data)
  ignore(
    @host.write_delta_reference(
      reference.spec,
      dir + "/wrong",
      dir + "/bad.delta",
      chunk_size=3,
    ),
  )
  assert_eq(@fs.read_file(dir + "/bad.delta").binary(), reference.to_bytes())
  try
    @host.write_delta_reference(
      reference.spec,
      dir + "/wrong",
      dir + "/wrong",
      chunk_size=3,
    )
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong publisher alias error")
  } noraise {
    _ => fail("replaced source")
  }
  assert_eq(@fs.read_file(dir + "/wrong").binary(), data)
}

///|
async test "bounded delta loading refuses bad pins, oversized files and directories without mutation" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-delta-load-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abc", 3)
  let path = dir + "/delta"
  let bytes = @fs.read_file(path).binary()
  try @host.load_delta_reference(path, @ledger.digest(b"wrong")) catch {
    @ledger.InvalidManifest(_) => ()
    _ => fail("wrong pin error")
  } noraise {
    _ => fail("accepted wrong pin")
  }
  assert_eq(@fs.read_file(path).binary(), bytes)
  let boundary = bytes + Bytes::make(16000000 - bytes.length(), b' ')
  @fs.write_file(dir + "/boundary", boundary)
  assert_eq(
    @host.load_delta_reference(dir + "/boundary", @ledger.digest(boundary)).to_bytes(),
    reference.to_bytes(),
  )
  @fs.write_file(dir + "/oversized", Bytes::make(16000001, b'x'))
  try
    @host.load_delta_reference(dir + "/oversized", @ledger.digest(bytes))
  catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong size error")
  } noraise {
    _ => fail("accepted oversized metadata")
  }
  try @host.load_delta_reference(dir, @ledger.digest(bytes)) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong kind error")
  } noraise {
    _ => fail("accepted directory")
  }
  assert_eq(
    @host.load_delta_reference(path, @ledger.digest(bytes)).to_bytes(),
    reference.to_bytes(),
  )
}
