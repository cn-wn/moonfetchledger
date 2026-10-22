///|
async test "multiple old versions contribute disjoint blocks to a verified session without artifact network" {
  let dir = @fs.tmpdir(prefix="mfl-seed-pool-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFabc!", 3)
  let a = dir + "/v0"
  let b = dir + "/v1"
  @fs.write_file(a, b"xx!abc")
  @fs.write_file(b, b"DEFabc")
  let preview = @host.preview_seeds(reference, [a, b])
  assert_eq(preview.per_seed_reused_bytes(), [7L, 3L])
  assert_eq(preview.download_bytes(), 0L)
  let reversed = @host.preview_seeds(reference, [b, a])
  assert_eq(reversed.per_seed_reused_bytes(), [9L, 1L])
  let report = @host.reuse_from_seeds(reference, [a, b], dir + "/target")
  assert_true(report.complete)
  assert_eq(@fs.read_file(dir + "/target").binary(), b"abcDEFabc!")
  @host.export_verified(reference.spec, dir + "/target", dir + "/ready")
  assert_eq(@fs.read_file(dir + "/ready").binary(), b"abcDEFabc!")
  assert_eq(@fs.read_file(a).binary(), b"xx!abc")
  assert_eq(@fs.read_file(b).binary(), b"DEFabc")
}

///|
async test "pool errors preserve all seeds and foreign data before retrying sparse completion" {
  let dir = @fs.tmpdir(prefix="mfl-pool-errors-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = seed_reference(dir, b"abcDEFghi!", 3)
  let a = dir + "/a"
  let b = dir + "/b"
  let out = dir + "/out"
  @fs.write_file(a, b"!abc")
  @fs.write_file(b, b"DEF")
  for paths in [[], [a, a], [a, dir + "/./a"], [a, dir], Array::make(33, a)] {
    try @host.reuse_from_seeds(reference, paths, out) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong seed pool input error")
    } noraise {
      _ => fail("unsupported pool accepted")
    }
    assert_true(!@fs.exists(out + ".mfl.lock"))
  }
  for destination in [a, a + ".mfl", b + ".mfl.next"] {
    try @host.reuse_from_seeds(reference, [a, b], destination) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong pool alias error")
    } noraise {
      _ => fail("pool overwrote seed/session")
    }
  }
  let writer = @fs.open(b + ".mfl.lock", mode=ReadWrite, create_mode=CreateNew)
  assert_true(writer.try_lock(Exclusive))
  try @host.reuse_from_seeds(reference, [a, b], out) catch {
    @host.OutputLocked => ()
    _ => fail("wrong locked seed error")
  } noraise {
    _ => fail("pool ignored seed writer")
  }
  assert_true(!@fs.exists(out + ".mfl.lock"))
  writer.close()
  let preview = @host.preview_seeds(reference, [a, b])
  let result = @host.reuse_from_seeds(reference, [a, b], out)
  assert_eq(result.missing_ranges, preview.missing_ranges())
  assert_eq(result.reused_bytes, 7L)
  let ranges : Array[@ledger.ByteRange] = []
  assert_true(
    @host.receive_from(reference.spec, out, chunk_size=3, fetch_range=r => {
      ranges.push(r)
      {
        bytes: b"abcDEFghi!"[r.start.to_int():r.end.to_int()].to_owned(),
        status: 206,
        etag: reference.spec.etag,
        range: r,
        total: 10L,
        content_encoding: "identity",
      }
    }).complete,
  )
  assert_eq(ranges, [{ start: 6L, end: 9L, }])
  assert_eq(@fs.read_file(a).binary(), b"!abc")
  assert_eq(@fs.read_file(b).binary(), b"DEF")
}
