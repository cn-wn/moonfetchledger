///|
async test "export copies a verified artifact and preserves every source file" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-export-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/source"
  let destination = dir + "/ready"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(source, data)
  @host.adopt(spec, source, chunk_size=3)
  let checkpoint = @fs.read_file(source + ".mfl").binary()
  let lock = @fs.read_file(source + ".mfl.lock").binary()
  @host.export_verified(spec, source, destination)
  assert_eq(@fs.read_file(destination).binary(), data)
  assert_true(!@fs.exists(destination + ".next"))
  assert_eq(@fs.read_file(source).binary(), data)
  assert_eq(@fs.read_file(source + ".mfl").binary(), checkpoint)
  assert_eq(@fs.read_file(source + ".mfl.lock").binary(), lock)
  @fs.write_file(destination, b"unrelated")
  try @host.export_verified(spec, source, destination) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect existing-destination diagnostic")
  } noraise {
    _ => fail("overwrote destination")
  }
  assert_eq(@fs.read_file(destination).binary(), b"unrelated")
  assert_eq(@fs.read_file(source).binary(), data)
}

///|
async test "export refuses missing, corrupt and wrong-final-digest coverage" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-export-refusal-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/source"
  let destination = dir + "/ready"
  let spec = audit_spec(b"abcdefg")
  @fs.write_file(source, b"abcdefg")
  @fs.write_file(source + ".mfl.lock", b"")
  let partial = audit_checkpoint(spec, b"abcdefg", [0, 2])
  @fs.write_file(source + ".mfl", partial)
  try @host.export_verified(spec, source, destination) catch {
    @ledger.Incomplete(3L) => ()
    _ => fail("incorrect incomplete-export diagnostic")
  } noraise {
    _ => fail("exported incomplete coverage")
  }
  assert_eq(@fs.read_file(source + ".mfl").text(), partial)
  assert_true(!@fs.exists(destination) && !@fs.exists(destination + ".next"))
  let complete = audit_checkpoint(spec, b"abcdefg", [0, 1, 2])
  @fs.write_file(source + ".mfl", complete)
  @fs.write_file(source, b"Xbcdefg")
  try @host.export_verified(spec, source, destination) catch {
    @host.InvalidInput(message) =>
      assert_true(message.contains("recorded block [0,3)"))
    _ => fail("incorrect corruption diagnostic")
  } noraise {
    _ => fail("exported corrupted block")
  }
  assert_true(!@fs.exists(destination) && !@fs.exists(destination + ".next"))
  for bad in [b"abc", b"abcdefgh"] {
    @fs.write_file(source, bad)
    try @host.export_verified(spec, source, destination) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect source-length diagnostic")
    } noraise {
      _ => fail("trimmed or padded source")
    }
    assert_eq(@fs.read_file(source).binary(), bad)
  }
  let wrong = audit_spec(b"xyz")
  @fs.write_file(source, b"abc")
  let wrong_checkpoint = audit_checkpoint(wrong, b"abc", [0])
  @fs.write_file(source + ".mfl", wrong_checkpoint)
  try @host.export_verified(wrong, source, destination) catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("incorrect export-integrity diagnostic")
  } noraise {
    _ => fail("published wrong final digest")
  }
  assert_true(!@fs.exists(destination) && !@fs.exists(destination + ".next"))
  assert_eq(@fs.read_file(source + ".mfl").text(), wrong_checkpoint)
  @fs.write_file(source + ".mfl", wrong_checkpoint + "unknown")
  try @host.export_verified(wrong, source, destination) catch {
    @ledger.InvalidCheckpoint(_) => ()
    _ => fail("incorrect export-checkpoint diagnostic")
  } noraise {
    _ => fail("discarded unsupported checkpoint data")
  }
  assert_eq(@fs.read_file(source + ".mfl").text(), wrong_checkpoint + "unknown")
  @fs.remove(source + ".mfl")
  @host.adopt(audit_spec(b"abc"), source)
  @host.export_verified(audit_spec(b"abc"), source, destination)
  assert_eq(@fs.read_file(destination).binary(), b"abc")
}

///|
async test "export locks, empty artifact, temporary ownership and source path aliases" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-export-lock-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/empty"
  let destination = dir + "/ready"
  let spec = audit_spec(b"")
  @fs.write_file(source, b"")
  @host.adopt(spec, source)
  let lock = @fs.open(source + ".mfl.lock", mode=ReadWrite)
  defer lock.close()
  assert_true(lock.try_lock(Exclusive))
  try @host.export_verified(spec, source, destination) catch {
    @host.OutputLocked => ()
    _ => fail("incorrect export lock diagnostic")
  } noraise {
    _ => fail("exported while writer held source lock")
  }
  assert_true(!@fs.exists(destination))
  lock.unlock()
  for
    reserved in [
      source,
      source + ".mfl",
      source + ".mfl.lock",
      source + ".mfl.next",
      dir + "/./empty.mfl.next",
    ] {
    try @host.export_verified(spec, source, reserved) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect reserved-path diagnostic")
    } noraise {
      _ => fail("exported into a source session path")
    }
  }
  assert_true(!@fs.exists(source + ".mfl.next"))
  @fs.write_file(destination + ".next", b"unrelated")
  try @host.export_verified(spec, source, destination) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect export temporary diagnostic")
  } noraise {
    _ => fail("overwrote unrelated export temporary")
  }
  assert_eq(@fs.read_file(destination + ".next").binary(), b"unrelated")
  @fs.remove(destination + ".next")
  @host.export_verified(spec, source, destination)
  assert_eq(@fs.file_size(destination), 0L)
  assert_true(@host.audit(spec, source).complete)
}
