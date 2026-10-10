///|
async test "pending checkpoint promotion preserves artifact and consumes only validated candidate" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-promote-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  let old = audit_checkpoint(spec, data, [0])
  let next = audit_checkpoint(spec, data, [0, 1, 2])
  @fs.write_file(path, data)
  @fs.write_file(path + ".mfl.lock", b"retained lock")
  @fs.write_file(path + ".mfl", old)
  @fs.write_file(path + ".mfl.next", next)
  let report = @host.recover_checkpoint(spec, path)
  assert_true(report.complete)
  assert_eq(report.confirmed_bytes, 7L)
  assert_true(report.invalidated.is_empty() && report.missing_ranges.is_empty())
  assert_eq(@fs.read_file(path).binary(), data)
  assert_eq(@fs.read_file(path + ".mfl").text(), next)
  assert_eq(@fs.read_file(path + ".mfl.lock").binary(), b"retained lock")
  assert_true(
    !@fs.exists(path + ".mfl.next") && !@fs.exists(path + ".mfl.recovering"),
  )
  assert_true(@host.audit(spec, path).complete)
  try @host.recover_checkpoint(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect missing candidate diagnostic")
  } noraise {
    _ => fail("invented a missing candidate")
  }
  assert_eq(@fs.read_file(path + ".mfl").text(), next)
}

///|
async test "checkpoint promotion admits exactly the actual coverage supersets" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-masks-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(path, data)
  @fs.write_file(path + ".mfl.lock", b"")
  for current in 0..<8 {
    for candidate in 0..<8 {
      let old = audit_checkpoint(
        spec,
        data,
        [0, 1, 2].iter().filter(i => (current & (1 << i)) != 0).collect(),
      )
      let next = audit_checkpoint(
        spec,
        data,
        [0, 1, 2].iter().filter(i => (candidate & (1 << i)) != 0).collect(),
      )
      @fs.write_file(path + ".mfl", old)
      @fs.write_file(path + ".mfl.next", next)
      if (current & candidate) == current {
        let report = @host.recover_checkpoint(spec, path)
        assert_eq(report.complete, candidate == 7)
        assert_eq(@fs.read_file(path + ".mfl").text(), next)
        assert_true(!@fs.exists(path + ".mfl.next"))
      } else {
        try @host.recover_checkpoint(spec, path) catch {
          @host.InvalidInput(message) =>
            assert_true(message.contains("lose valid recorded coverage"))
          _ => fail("incorrect stale candidate diagnostic")
        } noraise {
          _ => fail("lost valid recorded coverage")
        }
        assert_eq(@fs.read_file(path + ".mfl").text(), old)
        assert_eq(@fs.read_file(path + ".mfl.next").text(), next)
      }
      assert_eq(@fs.read_file(path).binary(), data)
      assert_true(!@fs.exists(path + ".mfl.recovering"))
    }
  }
}

///|
async test "candidate recovery reports sorted distinct failed records and retains valid data" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-corrupt-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abcdefghij"
  let damaged = b"XbcdefXhij"
  let spec = audit_spec(data)
  @fs.write_file(path, damaged)
  @fs.write_file(path + ".mfl.lock", b"")
  @fs.write_file(path + ".mfl", audit_checkpoint(spec, data, [0, 1, 2, 3]))
  @fs.write_file(path + ".mfl.next", audit_checkpoint(spec, data, [0, 1, 3]))
  let report = @host.recover_checkpoint(spec, path)
  assert_true(!report.complete)
  assert_eq(report.confirmed_bytes, 4L)
  assert_eq(report.invalidated, [
    { start: 0L, end: 3L, },
    { start: 6L, end: 9L, },
  ])
  assert_eq(report.missing_ranges, [
    { start: 0L, end: 3L, },
    { start: 6L, end: 9L, },
  ])
  assert_eq(
    @fs.read_file(path + ".mfl").text(),
    audit_checkpoint(spec, data, [1, 3]),
  )
  assert_eq(@fs.read_file(path).binary(), damaged)
  @fs.remove(path)
  @fs.rename(path + ".mfl", path + ".mfl.next")
  let absent = @host.recover_checkpoint(spec, path)
  assert_true(!absent.complete && !absent.output_present)
  assert_eq(absent.confirmed_bytes, 0L)
  assert_eq(absent.invalidated, [
    { start: 3L, end: 6L, },
    { start: 9L, end: 10L, },
  ])
  assert_true(!@fs.exists(path))
}

///|
async test "schema identity layout extra bytes and final digest failures preserve recovery inputs" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-refusal-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let data = b"abc"
  let spec = audit_spec(data)
  let old = audit_checkpoint(spec, data, [])
  let other = audit_spec(b"xyz")
  @fs.write_file(path, data)
  @fs.write_file(path + ".mfl.lock", b"")
  @fs.write_file(path + ".mfl", old)
  for
    next in [
      "malformed",
      old + "extra",
      audit_checkpoint(other, b"xyz", [0]),
      @ledger.Session::new(spec, chunk_size=2).checkpoint(),
    ] {
    @fs.write_file(path + ".mfl.next", next)
    try @host.recover_checkpoint(spec, path) catch {
      @ledger.InvalidCheckpoint(_) | @host.InvalidInput(_) => ()
      _ => fail("incorrect candidate refusal")
    } noraise {
      _ => fail("accepted invalid candidate")
    }
    assert_eq(@fs.read_file(path + ".mfl").text(), old)
    assert_eq(@fs.read_file(path + ".mfl.next").text(), next)
    assert_eq(@fs.read_file(path).binary(), data)
  }
  let next = audit_checkpoint(spec, data, [0])
  @fs.write_file(path + ".mfl.next", next)
  @fs.write_file(path, b"abcd")
  try @host.recover_checkpoint(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect extra-data refusal")
  } noraise {
    _ => fail("trimmed extra data")
  }
  assert_eq(@fs.read_file(path).binary(), b"abcd")
  assert_eq(@fs.read_file(path + ".mfl").text(), old)
  assert_eq(@fs.read_file(path + ".mfl.next").text(), next)
  @fs.write_file(path, data)
  @fs.write_file(path + ".mfl", audit_checkpoint(other, data, []))
  let bad_whole = audit_checkpoint(other, data, [0])
  @fs.write_file(path + ".mfl.next", bad_whole)
  try @host.recover_checkpoint(other, path) catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("incorrect final SHA refusal")
  } noraise {
    _ => fail("promoted complete bad whole digest")
  }
  assert_eq(@fs.read_file(path + ".mfl.next").text(), bad_whole)
  assert_eq(
    @fs.read_file(path + ".mfl").text(),
    audit_checkpoint(other, data, []),
  )
}

///|
async test "checkpoint temporaries are never overwritten and recovery respects locks and bounds" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-ownership-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/object"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/empty",
    0L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  for suffix in [".mfl.next", ".mfl.recovering"] {
    @fs.write_file(path + suffix, b"unrelated")
    try @host.download(spec, path) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect retained temporary diagnostic")
    } noraise {
      _ => fail("overwrote an existing temporary")
    }
    assert_eq(@fs.read_file(path + suffix).binary(), b"unrelated")
    assert_true(
      !@fs.exists(path) &&
      !@fs.exists(path + ".mfl") &&
      !@fs.exists(path + ".mfl.lock"),
    )
    @fs.remove(path + suffix)
  }
  let lock = @fs.open(path + ".mfl.lock", mode=ReadWrite, create_mode=CreateNew)
  assert_true(lock.try_lock(Exclusive))
  let next = @ledger.Session::new(spec).checkpoint()
  @fs.write_file(path + ".mfl.next", next)
  try @host.recover_checkpoint(spec, path) catch {
    @host.OutputLocked => ()
    _ => fail("incorrect competing recovery diagnostic")
  } noraise {
    _ => fail("ignored exclusive writer")
  }
  lock.close()
  @fs.write_file(path + ".mfl.recovering", b"retained recovery")
  try @host.recover_checkpoint(spec, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect recovery temporary diagnostic")
  } noraise {
    _ => fail("overwrote interrupted recovery")
  }
  assert_eq(
    @fs.read_file(path + ".mfl.recovering").binary(),
    b"retained recovery",
  )
  @fs.remove(path + ".mfl.recovering")
  let large = @fs.open(path + ".mfl.next", mode=ReadWrite)
  large.write_at(b"x", position=16000000L)
  large.close()
  try @host.recover_checkpoint(spec, path) catch {
    @host.CheckpointTooLarge => ()
    _ => fail("incorrect checkpoint size diagnostic")
  } noraise {
    _ => fail("accepted oversized checkpoint")
  }
  assert_eq(@fs.file_size(path + ".mfl.next"), 16000001L)
  @fs.write_file(path + ".mfl.next", next)
  let recovered = @host.recover_checkpoint(spec, path)
  assert_true(!recovered.output_present && !recovered.complete)
  assert_true(@host.download(spec, path).complete)
}
