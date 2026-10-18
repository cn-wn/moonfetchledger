///|
async fn adoption_reference(
  directory : String,
  data : Bytes,
) -> @ledger.BlockReference {
  let source = directory + "/publisher"
  let metadata = directory + "/reference"
  @fs.write_file(source, data)
  let pin = @host.write_block_reference(
    audit_spec(data),
    source,
    metadata,
    chunk_size=3,
  )
  @host.load_block_reference(audit_spec(data), metadata, pin)
}

///|
async test "reference adoption reconstructs exactly actual coverage for every damage mask" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-adopt-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcdefg"
  let spec = audit_spec(data)
  let reference = adoption_reference(dir, data)
  let metadata = @fs.read_file(dir + "/reference").binary()
  for mask in 0..<8 {
    let path = dir + "/target-\{mask}"
    let damaged = Bytes::makei(7, i => {
      if (mask & (1 << (i / 3))) != 0 {
        data[i]
      } else {
        b'\xff'
      }
    })
    @fs.write_file(path, damaged)
    let before = @host.audit_with_reference(reference, path)
    let adopted = @host.adopt_with_reference(reference, path)
    assert_eq(adopted.to_json(), before.to_json())
    assert_eq(@fs.read_file(path).binary(), damaged)
    let valid = [0, 1, 2].iter().filter(i => (mask & (1 << i)) != 0).collect()
    assert_eq(
      @fs.read_file(path + ".mfl").text(),
      audit_checkpoint(spec, data, valid),
    )
    assert_eq(@host.audit(spec, path).confirmed_bytes, adopted.confirmed_bytes)
    assert_true(
      !@fs.exists(path + ".mfl.next") && !@fs.exists(path + ".mfl.recovering"),
    )
    let repaired = @host.repair_from_local(spec, path, dir + "/publisher")
    assert_true(repaired.complete)
    assert_eq(repaired.repaired_blocks, 3 - valid.length())
    assert_eq(repaired.recovery.retained_bytes, adopted.confirmed_bytes)
    assert_eq(@fs.read_file(path).binary(), data)
    assert_eq(@fs.read_file(path + ".mfl").text(), reference.to_checkpoint())
    assert_eq(@fs.read_file(dir + "/reference").binary(), metadata)
  }
}

///|
async test "reference adoption preserves existing checkpoints and unrelated temporaries" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-preserve-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = adoption_reference(dir, b"abc")
  let path = dir + "/target"
  @fs.write_file(path, b"Xbc")
  for suffix in [".mfl", ".mfl.next", ".mfl.recovering"] {
    @fs.write_file(path + suffix, b"unrelated metadata")
    try @host.adopt_with_reference(reference, path) catch {
      @host.InvalidInput(message) => assert_true(message.contains("preserve"))
      _ => fail("wrong retained metadata diagnostic")
    } noraise {
      _ => fail("overwrote existing session metadata")
    }
    assert_eq(@fs.read_file(path + suffix).binary(), b"unrelated metadata")
    assert_eq(@fs.read_file(path).binary(), b"Xbc")
    assert_true(!@fs.exists(path + ".mfl.lock"))
    @fs.remove(path + suffix)
  }
  let report = @host.adopt_with_reference(reference, path)
  assert_true(!report.complete)
  let checkpoint = @fs.read_file(path + ".mfl").binary()
  try @host.adopt_with_reference(reference, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong repeated-adoption diagnostic")
  } noraise {
    _ => fail("silently reset existing progress")
  }
  assert_eq(@fs.read_file(path + ".mfl").binary(), checkpoint)
  assert_eq(@fs.read_file(path).binary(), b"Xbc")
}

///|
async test "reference adoption rejects invalid paths and whole digests but accepts truncation and empty files" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-boundary-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = adoption_reference(dir, b"abcdefg")
  let path = dir + "/target"
  for absent in [path, ""] {
    try @host.adopt_with_reference(reference, absent) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong absent artifact diagnostic")
    } noraise {
      _ => fail("adopted absent artifact")
    }
  }
  assert_true(!@fs.exists(path + ".mfl.lock"))
  @fs.mkdir(path)
  try @host.adopt_with_reference(reference, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong regular-artifact diagnostic")
  } noraise {
    _ => fail("adopted a directory")
  }
  @fs.rmdir(path)
  @fs.write_file(path, b"abcdefgh")
  try @host.adopt_with_reference(reference, path) catch {
    @host.InvalidInput(message) => assert_true(message.contains("extra data"))
    _ => fail("wrong extra-byte diagnostic")
  } noraise {
    _ => fail("truncated artifact to fit reference")
  }
  assert_eq(@fs.read_file(path).binary(), b"abcdefgh")
  assert_true(!@fs.exists(path + ".mfl") && !@fs.exists(path + ".mfl.next"))
  @fs.write_file(path, b"abcde")
  let short = @host.adopt_with_reference(reference, path)
  assert_eq(short.confirmed_bytes, 3L)
  assert_eq(short.missing_ranges, [{ start: 3L, end: 7L, }])
  assert_eq(@fs.read_file(path).binary(), b"abcde")
  let empty_dir = dir + "/empty-fixture"
  @fs.mkdir(empty_dir)
  let empty_ref = adoption_reference(empty_dir, b"")
  let empty = dir + "/empty"
  @fs.write_file(empty, b"")
  assert_true(@host.adopt_with_reference(empty_ref, empty).complete)
  let bad_spec = audit_spec(b"xyz")
  let bad_path = dir + "/wrong-whole"
  @fs.write_file(bad_path, b"abc")
  let text = audit_checkpoint(bad_spec, b"abc", [0])
  @fs.write_file(dir + "/bad-reference", text)
  let pin = @ledger.digest(@fs.read_file(dir + "/bad-reference").binary())
  let bad = @host.load_block_reference(bad_spec, dir + "/bad-reference", pin)
  try @host.adopt_with_reference(bad, bad_path) catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("wrong whole-integrity refusal")
  } noraise {
    _ => fail("published complete checkpoint with bad whole digest")
  }
  assert_eq(@fs.read_file(bad_path).binary(), b"abc")
  assert_true(
    !@fs.exists(bad_path + ".mfl") && !@fs.exists(bad_path + ".mfl.next"),
  )
}

///|
async test "reference adoption respects competing locks and permits safe retry" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-compete-")
  defer @fs.rmdir(dir, recursive=true)
  let reference = adoption_reference(dir, b"abc")
  let path = dir + "/target"
  @fs.write_file(path, b"abc")
  @fs.mkdir(path + ".mfl.lock")
  try @host.adopt_with_reference(reference, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong regular-lock refusal")
  } noraise {
    _ => fail("accepted directory lock")
  }
  @fs.rmdir(path + ".mfl.lock")
  @fs.write_file(path + ".mfl.lock", b"retained lock contents")
  let lock = @fs.open(path + ".mfl.lock", mode=ReadWrite)
  assert_true(lock.try_lock(Shared))
  try @host.adopt_with_reference(reference, path) catch {
    @host.OutputLocked => ()
    _ => fail("wrong competing-reader diagnostic")
  } noraise {
    _ => fail("adopted while cooperating reader was active")
  }
  assert_true(!@fs.exists(path + ".mfl"))
  lock.close()
  assert_true(@host.adopt_with_reference(reference, path).complete)
  assert_eq(
    @fs.read_file(path + ".mfl.lock").binary(),
    b"retained lock contents",
  )
  assert_eq(@fs.read_file(path).binary(), b"abc")
  assert_true(@host.audit(reference.spec, path).complete)
}
