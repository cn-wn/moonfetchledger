///|
fn audit_spec(bytes : Bytes) -> @ledger.ObjectSpec raise {
  @ledger.ObjectSpec::new(
    "https://example.test/offline",
    bytes.length().to_int64(),
    "\"v1\"",
    @ledger.digest(bytes),
  )
}

///|
fn audit_checkpoint(
  spec : @ledger.ObjectSpec,
  bytes : Bytes,
  indices : Array[Int],
) -> String raise {
  let s = @ledger.Session::new(spec, chunk_size=3)
  let mut index = 0
  while s.reserve_missing() is Some(lease) {
    if indices.contains(index) {
      let body = bytes[lease.range.start.to_int():lease.range.end.to_int()].to_owned()
      let prepared = s.prepare_chunk(
        lease,
        body,
        status=206,
        etag=spec.etag,
        range=lease.range,
        total=spec.length,
      )
      s.commit_written(prepared, body)
    }
    index += 1
  }
  s.checkpoint()
}

///|
async test "audit coalesces gaps and reports corruption without modifying session files" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-audit-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  let checkpoint = audit_checkpoint(spec, data, [0, 2])
  @fs.write_file(path, data)
  @fs.write_file(path + ".mfl", checkpoint)
  @fs.write_file(path + ".mfl.lock", b"lock marker")
  let first = @host.audit(spec, path)
  assert_true(!first.complete && first.output_present)
  assert_eq(first.confirmed_bytes, 4L)
  assert_eq(first.missing_ranges, [{ start: 3L, end: 6L, }])
  assert_true(first.invalidated.is_empty())
  @fs.write_file(path, b"Xbcdefg")
  let bad = @host.audit(spec, path)
  assert_eq(bad.confirmed_bytes, 1L)
  assert_eq(bad.invalidated, [{ start: 0L, end: 3L, }])
  assert_eq(bad.missing_ranges, [{ start: 0L, end: 6L, }])
  assert_eq(
    bad.to_json().stringify(),
    "[\"MFLAUDIT1\",false,true,\"7\",\"1\",[[\"0\",\"6\"]],[[\"0\",\"3\"]]]",
  )
  assert_eq(@host.audit(spec, path).to_json(), bad.to_json())
  assert_eq(@fs.read_file(path).binary(), b"Xbcdefg")
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  assert_eq(@fs.read_file(path + ".mfl.lock").binary(), b"lock marker")
  assert_true(!@fs.exists(path + ".mfl.next"))
  @fs.remove(path)
  let absent = @host.audit(spec, path)
  assert_true(!absent.complete && !absent.output_present)
  assert_eq(absent.stored_bytes, 0L)
  assert_eq(absent.confirmed_bytes, 0L)
  assert_eq(absent.missing_ranges, [{ start: 0L, end: 7L, }])
  assert_eq(absent.invalidated, [
    { start: 0L, end: 3L, },
    { start: 6L, end: 7L, },
  ])
  assert_true(!@fs.exists(path))
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
}

///|
async test "audit verifies final SHA and refuses extra bytes, schema and identity changes" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-audit-final-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abc"
  let spec = audit_spec(data)
  let checkpoint = audit_checkpoint(spec, data, [0])
  @fs.write_file(path, data)
  @fs.write_file(path + ".mfl", checkpoint)
  @fs.write_file(path + ".mfl.lock", b"")
  assert_true(@host.audit(spec, path).complete)
  @fs.write_file(path, b"a")
  let short = @host.audit(spec, path)
  assert_eq(short.stored_bytes, 1L)
  assert_eq(short.invalidated, [{ start: 0L, end: 3L, }])
  assert_eq(@fs.read_file(path).binary(), b"a")
  @fs.write_file(path, b"abcd")
  try @host.audit(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect extra-byte diagnostic")
  } noraise {
    _ => fail("ignored trailing bytes")
  }
  assert_eq(@fs.read_file(path).binary(), b"abcd")
  @fs.write_file(path, data)
  let wrong = audit_spec(b"xyz")
  let wrong_checkpoint = audit_checkpoint(wrong, data, [0])
  @fs.write_file(path + ".mfl", wrong_checkpoint)
  try @host.audit(wrong, path) catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("incorrect final-integrity diagnostic")
  } noraise {
    _ => fail("equated per-block coverage with whole-file integrity")
  }
  assert_eq(@fs.read_file(path + ".mfl").text(), wrong_checkpoint)
  try @host.audit(spec, path) catch {
    @ledger.InvalidCheckpoint(_) => ()
    _ => fail("incorrect identity diagnostic")
  } noraise {
    _ => fail("accepted different expected identity")
  }
  @fs.write_file(path + ".mfl", checkpoint + "unknown")
  try @host.audit(spec, path) catch {
    @ledger.InvalidCheckpoint(_) => ()
    _ => fail("incorrect malformed-schema diagnostic")
  } noraise {
    _ => fail("accepted trailing checkpoint data")
  }
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint + "unknown")
  assert_eq(@fs.read_file(path).binary(), data)
}

///|
async test "read-only shared audit locks, missing sidecars and absent empty output" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-audit-lock-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/empty"
  let spec = audit_spec(b"")
  try @host.audit(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect missing-session diagnostic")
  } noraise {
    _ => fail("invented an audit session")
  }
  assert_eq(@fs.readdir(dir).length(), 0)
  @fs.write_file(path + ".mfl", audit_checkpoint(spec, b"", []))
  @fs.write_file(path + ".mfl.lock", b"")
  let lock = @fs.open(path + ".mfl.lock", mode=ReadWrite)
  defer lock.close()
  assert_true(lock.try_lock(Exclusive))
  try @host.audit(spec, path) catch {
    @host.OutputLocked => ()
    _ => fail("incorrect competing-writer diagnostic")
  } noraise {
    _ => fail("audited while writer held lock")
  }
  lock.unlock()
  assert_true(lock.try_lock(Shared))
  let missing = @host.audit(spec, path)
  assert_true(!missing.complete && !missing.output_present)
  assert_true(missing.missing_ranges.is_empty())
  assert_true(!@fs.exists(path))
  @fs.write_file(path, b"")
  let present = @host.audit(spec, path)
  assert_true(present.complete && present.output_present)
  assert_eq(present.confirmed_bytes, 0L)
}
