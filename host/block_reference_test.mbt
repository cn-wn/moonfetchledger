///|
async test "published pinned block references audit unmanaged damage without creating sidecars" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-audit-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/source"
  let path = dir + "/unmanaged"
  let catalog = dir + "/blocks.mfl"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(source, data)
  let pin = @host.write_block_reference(spec, source, catalog, chunk_size=3)
  let bytes = @fs.read_file(catalog).binary()
  assert_eq(pin, @ledger.digest(bytes))
  assert_eq(
    @fs.read_file(catalog).text(),
    audit_checkpoint(spec, data, [0, 1, 2]),
  )
  let reference = @host.load_block_reference(spec, catalog, pin)
  for
    (actual, retained, complete) in [
      (data, 7L, true),
      (b"Xbcdefg", 4L, false),
      (b"abcde", 3L, false),
      (b"", 0L, false),
    ] {
    @fs.write_file(path, actual)
    let report = @host.audit_with_reference(reference, path)
    assert_eq(report.confirmed_bytes, retained)
    assert_eq(report.complete, complete)
    assert_eq(report.stored_bytes, actual.length().to_int64())
    assert_eq(
      @host.audit_with_reference(reference, path).to_json(),
      report.to_json(),
    )
    assert_eq(@fs.read_file(path).binary(), actual)
    assert_eq(@fs.read_file(catalog).binary(), bytes)
    for suffix in [".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
      assert_true(!@fs.exists(path + suffix) && !@fs.exists(source + suffix))
    }
  }
  @fs.remove(path)
  let missing = @host.audit_with_reference(reference, path)
  assert_true(!missing.complete && !missing.output_present)
  assert_eq(missing.confirmed_bytes, 0L)
  assert_eq(missing.missing_ranges, [{ start: 0L, end: 7L, }])
  assert_eq(missing.invalidated.length(), 3)
  assert_true(!@fs.exists(path))
  @fs.write_file(path, b"abcdefgh")
  try @host.audit_with_reference(reference, path) catch {
    @host.InvalidInput(message) => assert_true(message.contains("extra data"))
    _ => fail("wrong reference audit diagnostic")
  } noraise {
    _ => fail("ignored extra artifact bytes")
  }
  assert_eq(@fs.read_file(path).binary(), b"abcdefgh")
}

///|
async test "reference publication refuses bad sources aliases and owned paths without replacing data" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-publication-")
  defer @fs.rmdir(dir, recursive=true)
  let source = dir + "/source"
  let destination = dir + "/blocks"
  let spec = audit_spec(b"abc")
  for bad in [b"ab", b"abcd", b"xyz"] {
    @fs.write_file(source, bad)
    try @host.write_block_reference(spec, source, destination) catch {
      @host.InvalidInput(_) | @ledger.DigestMismatch(_) => ()
      _ => fail("wrong source verification diagnostic")
    } noraise {
      _ => fail("published reference from invalid source")
    }
    assert_eq(@fs.read_file(source).binary(), bad)
    assert_true(!@fs.exists(destination) && !@fs.exists(destination + ".next"))
  }
  @fs.write_file(source, b"abc")
  for suffix in ["", ".mfl", ".mfl.lock", ".mfl.next", ".mfl.recovering"] {
    try @host.write_block_reference(spec, source, source + suffix) catch {
      @host.InvalidInput(_) => ()
      _ => fail("wrong alias diagnostic")
    } noraise {
      _ => fail("published into source session paths")
    }
    assert_eq(@fs.read_file(source).binary(), b"abc")
  }
  @fs.write_file(destination + ".next", b"unrelated temporary")
  try @host.write_block_reference(spec, source, destination) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong temporary ownership diagnostic")
  } noraise {
    _ => fail("overwrote existing temporary")
  }
  assert_eq(
    @fs.read_file(destination + ".next").binary(),
    b"unrelated temporary",
  )
  @fs.remove(destination + ".next")
  let pin = @host.write_block_reference(spec, source, destination)
  let saved = @fs.read_file(destination).binary()
  try @host.write_block_reference(spec, source, destination) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong destination ownership diagnostic")
  } noraise {
    _ => fail("replaced existing reference")
  }
  assert_eq(@fs.read_file(destination).binary(), saved)
  assert_true(
    @host.audit_with_reference(
      @host.load_block_reference(spec, destination, pin),
      source,
    ).complete,
  )
}

///|
async test "reference loaders preserve malformed oversized and exact-boundary metadata" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-input-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/blocks"
  let spec = audit_spec(b"")
  for bytes in [b"\xff", b"[", b"[]"] {
    @fs.write_file(path, bytes)
    try @host.load_block_reference(spec, path, @ledger.digest(bytes)) catch {
      @ledger.InvalidCheckpoint(_) => ()
      _ => fail("wrong reference input diagnostic")
    } noraise {
      _ => fail("accepted malformed reference")
    }
    assert_eq(@fs.read_file(path).binary(), bytes)
  }
  let text = audit_checkpoint(spec, b"", [])
  @fs.write_file(path, text + " ".repeat(16000000 - text.length()))
  let bytes = @fs.read_file(path).binary()
  assert_eq(
    @host.load_block_reference(spec, path, @ledger.digest(bytes)).spec,
    spec,
  )
  let file = @fs.open(path, mode=ReadWrite)
  file.write_at(b" ", position=16000000L)
  file.close()
  try @host.load_block_reference(spec, path, @ledger.digest(bytes)) catch {
    @host.CheckpointTooLarge => ()
    _ => fail("wrong reference byte-bound diagnostic")
  } noraise {
    _ => fail("accepted oversized reference file")
  }
  assert_eq(@fs.file_size(path), 16000001L)
  @fs.write_file(path, text)
  let reference = @host.load_block_reference(
    spec,
    path,
    @ledger.digest(@fs.read_file(path).binary()),
  )
  assert_true(!@host.audit_with_reference(reference, dir + "/absent").complete)
  @fs.write_file(dir + "/empty", b"")
  assert_true(@host.audit_with_reference(reference, dir + "/empty").complete)
}

///|
async test "reference audits cooperate with existing locks and still verify whole content" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-reference-lock-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/artifact"
  let data = b"abc"
  let spec = audit_spec(data)
  @fs.write_file(path, data)
  let pin = @host.write_block_reference(spec, path, dir + "/blocks")
  let reference = @host.load_block_reference(spec, dir + "/blocks", pin)
  @fs.write_file(path + ".mfl", b"untrusted local metadata")
  try @host.audit_with_reference(reference, path) catch {
    @host.InvalidInput(_) => ()
    _ => fail("wrong missing-lock diagnostic")
  } noraise {
    _ => fail("ignored missing session lock")
  }
  let lock = @fs.open(path + ".mfl.lock", mode=ReadWrite, create_mode=CreateNew)
  assert_true(lock.try_lock(Exclusive))
  try @host.audit_with_reference(reference, path) catch {
    @host.OutputLocked => ()
    _ => fail("wrong locked audit diagnostic")
  } noraise {
    _ => fail("ignored existing writer")
  }
  try @host.write_block_reference(spec, path, dir + "/blocked") catch {
    @host.OutputLocked => ()
    _ => fail("wrong locked publisher diagnostic")
  } noraise {
    _ => fail("published while cooperating writer held lock")
  }
  lock.close()
  assert_true(@host.audit_with_reference(reference, path).complete)
  assert_eq(@fs.read_file(path + ".mfl").binary(), b"untrusted local metadata")
  let other = audit_spec(b"xyz")
  @fs.write_file(dir + "/bad-reference", audit_checkpoint(other, data, [0]))
  let bad_pin = @ledger.digest(@fs.read_file(dir + "/bad-reference").binary())
  let bad = @host.load_block_reference(other, dir + "/bad-reference", bad_pin)
  try @host.audit_with_reference(bad, path) catch {
    @ledger.DigestMismatch(_) => ()
    _ => fail("wrong final integrity diagnostic")
  } noraise {
    _ => fail("accepted block coverage with bad whole digest")
  }
  assert_eq(@fs.read_file(path).binary(), data)
}
