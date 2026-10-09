///|
async test "adoption preserves source and produces recoverable verified coverage" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-adopt-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(path, data)
  @host.adopt(spec, path, chunk_size=3)
  let checkpoint = @fs.read_file(path + ".mfl").text()
  assert_eq(checkpoint, audit_checkpoint(spec, data, [0, 1, 2]))
  assert_eq(@fs.read_file(path).binary(), data)
  assert_true(!@fs.exists(path + ".mfl.next"))
  assert_true(@host.audit(spec, path).complete)
  try @host.adopt(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect existing-session diagnostic")
  } noraise {
    _ => fail("overwrote existing checkpoint")
  }
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  @fs.write_file(path, b"Xbcdefg")
  let damaged = @host.audit(spec, path)
  assert_eq(damaged.confirmed_bytes, 4L)
  assert_eq(damaged.invalidated, [{ start: 0L, end: 3L, }])
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
}

///|
async test "adoption refuses bad bytes, wrong lengths and unrelated temporary files" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-adopt-refusal-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let spec = audit_spec(b"abc")
  for bad in [b"xyz", b"ab", b"abcd"] {
    @fs.write_file(path, bad)
    try @host.adopt(spec, path, chunk_size=2) catch {
      @host.InvalidInput(_) | @ledger.DigestMismatch(_) => ()
      _ => fail("incorrect invalid-local-content diagnostic")
    } noraise {
      _ => fail("created coverage for unsupported data")
    }
    assert_eq(@fs.read_file(path).binary(), bad)
    assert_true(!@fs.exists(path + ".mfl"))
    assert_true(!@fs.exists(path + ".mfl.next"))
  }
  @fs.write_file(path, b"abc")
  @fs.write_file(path + ".mfl.next", b"unrelated")
  try @host.adopt(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect temporary-file diagnostic")
  } noraise {
    _ => fail("overwrote unrelated temporary file")
  }
  assert_eq(@fs.read_file(path + ".mfl.next").binary(), b"unrelated")
  assert_true(!@fs.exists(path + ".mfl"))
  @fs.remove(path + ".mfl.next")
  @host.adopt(spec, path)
  assert_true(@host.audit(spec, path).complete)
}

///|
async test "adoption missing inputs, empty file and competing writer" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-adopt-lock-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/empty"
  let spec = audit_spec(b"")
  try @host.adopt(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect missing-source diagnostic")
  } noraise {
    _ => fail("created missing source")
  }
  assert_eq(@fs.readdir(dir).length(), 0)
  @fs.write_file(path, b"")
  let lock = @fs.open(path + ".mfl.lock", mode=ReadWrite, create_mode=CreateNew)
  assert_true(lock.try_lock(Exclusive))
  try @host.adopt(spec, path) catch {
    @host.OutputLocked => ()
    _ => fail("incorrect adoption lock diagnostic")
  } noraise {
    _ => fail("accepted competing writer")
  }
  assert_true(!@fs.exists(path + ".mfl"))
  lock.close()
  @host.adopt(spec, path)
  assert_true(@host.audit(spec, path).complete)
  assert_eq(@fs.file_size(path), 0L)
}
