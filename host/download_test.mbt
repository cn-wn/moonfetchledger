///|
async test "input refusal preserves unrelated files and old checkpoints" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-test-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/object",
    3L,
    "\"v1\"",
    @ledger.digest(b"abc"),
  )
  @fs.write_file(path, b"unrelated")
  try @host.download(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect existing-file diagnostic")
  } noraise {
    _ => fail("overwrote unrelated file")
  }
  assert_eq(@fs.read_file(path).binary(), b"unrelated")
  assert_true(!@fs.exists(path + ".mfl"))
  let session = @ledger.Session::new(spec, chunk_size=3)
  let checkpoint = session.checkpoint()
  @fs.write_file(path + ".mfl", checkpoint)
  try @host.download(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect extra-data diagnostic")
  } noraise {
    _ => fail("silently truncated extra data")
  }
  assert_eq(@fs.read_file(path).binary(), b"unrelated")
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
}

///|
async test "native file lock rejects a competing writer and permits later recovery" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-lock-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/empty"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/empty",
    0L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  let lock = @fs.open(
    path + ".mfl.lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
  )
  assert_true(lock.try_lock(Exclusive))
  try @host.download(spec, path) catch {
    @host.OutputLocked => ()
    _ => fail("incorrect lock diagnostic")
  } noraise {
    _ => fail("accepted competing writer")
  }
  assert_true(!@fs.exists(path))
  lock.close()
  let report = @host.download(spec, path)
  assert_true(report.complete)
  assert_eq(report.downloaded_blocks, 0)
  assert_eq(@fs.file_size(path), 0L)
  let checkpoint = @fs.read_file(path + ".mfl").text()
  let restored = @host.download(spec, path)
  assert_true(restored.complete)
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
}

///|
async test "restored block size and malformed checkpoint preservation" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-restore-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/large"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/large",
    100000000000L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  let paused = @host.download(
    spec,
    path,
    chunk_size=4194304,
    stop_after_blocks=0,
  )
  assert_true(!paused.complete)
  let checkpoint = @fs.read_file(path + ".mfl").text()
  let resumed = @host.download(spec, path, stop_after_blocks=0)
  assert_true(!resumed.complete)
  assert_eq(@fs.read_file(path + ".mfl").text(), checkpoint)
  let malformed = checkpoint + "unknown"
  @fs.write_file(path + ".mfl", malformed)
  try @host.download(spec, path, stop_after_blocks=0) catch {
    @ledger.InvalidCheckpoint(_) => ()
    _ => fail("incorrect checkpoint diagnostic")
  } noraise {
    _ => fail("silently accepted trailing checkpoint data")
  }
  assert_eq(@fs.read_file(path + ".mfl").text(), malformed)
  assert_eq(@fs.file_size(path), 0L)
  for parallel in [0, 17] {
    try @host.download(spec, path, parallel~) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect parallelism diagnostic")
    } noraise {
      _ => fail("accepted invalid parallelism")
    }
  }
}
