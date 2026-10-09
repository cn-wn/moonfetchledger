///|
async test "local backup repair retains coverage, repairs truncation and is repeatable" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-repair-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(backup, data)
  @fs.write_file(path, b"Xbcdef")
  @fs.write_file(path + ".mfl", audit_checkpoint(spec, data, [0, 1, 2]))
  @fs.write_file(path + ".mfl.lock", b"")
  let report = @host.repair_from_local(spec, path, backup)
  assert_eq(report.repaired_blocks, 2)
  assert_eq(report.recovery.retained_bytes, 3L)
  assert_eq(report.recovery.invalidated, [
    { start: 0L, end: 3L, },
    { start: 6L, end: 7L, },
  ])
  assert_eq(@fs.read_file(path).binary(), data)
  assert_eq(@fs.read_file(backup).binary(), data)
  let checkpoint = @fs.read_file(path + ".mfl").text()
  assert_true(@host.audit(spec, path).complete)
  assert_eq(@host.repair_from_local(spec, path, backup).repaired_blocks, 0)
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  @fs.remove(path)
  assert_eq(@host.repair_from_local(spec, path, backup).repaired_blocks, 3)
  assert_eq(@fs.read_file(path).binary(), data)
}

///|
async test "invalid backup, extra target and temporary ownership fail without writes" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-refuse-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let data = b"abc"
  let spec = audit_spec(data)
  let checkpoint = audit_checkpoint(spec, data, [0])
  @fs.write_file(path, b"xbc")
  @fs.write_file(path + ".mfl", checkpoint)
  @fs.write_file(path + ".mfl.lock", b"")
  for bad in [b"xyz", b"ab", b"abcd"] {
    @fs.write_file(backup, bad)
    try @host.repair_from_local(spec, path, backup) catch {
      @host.InvalidInput(_) | @ledger.DigestMismatch(_) => ()
      _ => fail("incorrect backup diagnostic")
    } noraise {
      _ => fail("accepted invalid backup")
    }
    assert_eq(@fs.read_file(path).binary(), b"xbc")
    assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
    assert_eq(@fs.read_file(backup).binary(), bad)
  }
  @fs.write_file(backup, data)
  for extra in [false, true] {
    if extra {
      @fs.remove(path + ".mfl.next")
      @fs.write_file(path, b"abcd")
    } else {
      @fs.write_file(path + ".mfl.next", b"unrelated")
    }
    try @host.repair_from_local(spec, path, backup) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect refusal diagnostic")
    } noraise {
      _ => fail("discarded unsupported data")
    }
    assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
    if extra {
      assert_eq(@fs.read_file(path).binary(), b"abcd")
      assert_true(!@fs.exists(path + ".mfl.next"))
    } else {
      assert_eq(@fs.read_file(path + ".mfl.next").binary(), b"unrelated")
    }
  }
}

///|
async test "local repair handles empty data and refuses aliases or competing writers" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-local-empty-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let spec = audit_spec(b"")
  @fs.write_file(backup, b"")
  @fs.write_file(path + ".mfl", audit_checkpoint(spec, b"", []))
  @fs.write_file(path + ".mfl.lock", b"")
  let lock = @fs.open(path + ".mfl.lock", mode=ReadWrite)
  assert_true(lock.try_lock(Exclusive))
  try @host.repair_from_local(spec, path, backup) catch {
    @host.OutputLocked => ()
    _ => fail("incorrect lock diagnostic")
  } noraise {
    _ => fail("accepted competing writer")
  }
  lock.close()
  assert_eq(@host.repair_from_local(spec, path, backup).repaired_blocks, 0)
  assert_true(@host.audit(spec, path).complete)
  try @host.repair_from_local(spec, path, dir + "/./target") catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect alias diagnostic")
  } noraise {
    _ => fail("accepted same source and target")
  }
}
