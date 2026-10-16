///|
async fn use_checkpoint(
  operation : Int32,
  spec : @ledger.ObjectSpec,
  path : String,
  backup : String,
  destination : String,
) -> Unit {
  match operation {
    0 => ignore(@host.audit(spec, path))
    1 =>
      ignore(
        @host.receive_from(spec, path, fetch_range=_ => {
          fail("malformed checkpoint triggered a range request")
        }),
      )
    2 => @host.export_verified(spec, path, destination)
    _ => ignore(@host.repair_from_local(spec, path, backup))
  }
}

///|
async test "every native reader refuses malformed UTF-8 without mutation and can reopen" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-input-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let destination = dir + "/ready"
  let data = b"abcdefg"
  let spec = audit_spec(data)
  @fs.write_file(path, data)
  @fs.write_file(backup, data)
  @host.adopt(spec, path, chunk_size=3)
  let checkpoint = @fs.read_file(path + ".mfl").binary()
  for
    malformed in [
      b"\xff", b"\xc0\xaf", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xe2\x82",
    ] {
    for operation in 0..<4 {
      @fs.write_file(path + ".mfl", malformed)
      try use_checkpoint(operation, spec, path, backup, destination) catch {
        @host.InvalidInput(message) =>
          assert_true(message.contains("strict UTF-8"))
        _ => fail("lost actionable UTF-8 diagnostic")
      } noraise {
        _ => fail("accepted malformed UTF-8")
      }
      assert_eq(@fs.read_file(path + ".mfl").binary(), malformed)
      assert_eq(@fs.read_file(path).binary(), data)
      assert_eq(@fs.read_file(backup).binary(), data)
      assert_true(
        !@fs.exists(destination) && !@fs.exists(destination + ".next"),
      )
      assert_true(!@fs.exists(path + ".mfl.next"))
      @fs.write_file(path + ".mfl", checkpoint)
      assert_true(@host.audit(spec, path).complete)
    }
  }
  for operation in 0..<4 {
    use_checkpoint(operation, spec, path, backup, destination)
    assert_eq(@fs.read_file(path + ".mfl").binary(), checkpoint)
  }
  assert_eq(@fs.read_file(destination).binary(), data)
}

///|
async test "all native readers refuse checkpoint directories before storage mutation" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-kind-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let data = b"abc"
  let spec = audit_spec(data)
  @fs.write_file(path, data)
  @fs.write_file(backup, data)
  @fs.write_file(path + ".mfl.lock", b"retained lock")
  @fs.mkdir(path + ".mfl")
  @fs.write_file(path + ".mfl/retained", b"unrelated")
  for operation in 0..<4 {
    try use_checkpoint(operation, spec, path, backup, dir + "/ready") catch {
      @host.InvalidInput(message) =>
        assert_true(message.contains("regular file"))
      _ => fail("lost regular-file diagnostic")
    } noraise {
      _ => fail("accepted directory checkpoint")
    }
    assert_eq(@fs.read_file(path + ".mfl/retained").binary(), b"unrelated")
    assert_eq(@fs.read_file(path + ".mfl.lock").binary(), b"retained lock")
    assert_eq(@fs.read_file(path).binary(), data)
    assert_true(!@fs.exists(dir + "/ready") && !@fs.exists(path + ".mfl.next"))
  }
}

///|
async test "checkpoint byte cap includes its boundary and preserves oversized input" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-boundary-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/target"
  let backup = dir + "/backup"
  let spec = audit_spec(b"")
  @fs.write_file(path, b"")
  @fs.write_file(backup, b"")
  @host.adopt(spec, path)
  let original = @fs.read_file(path + ".mfl").text()
  let padded = original + String::make(16000000 - original.length(), ' ')
  @fs.write_file(path + ".mfl", padded)
  assert_true(@host.audit(spec, path).complete)
  assert_eq(@fs.file_size(path + ".mfl"), 16000000L)
  let file = @fs.open(path + ".mfl", mode=ReadWrite)
  file.write_at(b" ", position=16000000L)
  file.close()
  for operation in 0..<4 {
    try use_checkpoint(operation, spec, path, backup, dir + "/ready") catch {
      @host.CheckpointTooLarge => ()
      _ => fail("lost checkpoint size diagnostic")
    } noraise {
      _ => fail("accepted oversized checkpoint")
    }
    assert_eq(@fs.file_size(path + ".mfl"), 16000001L)
    assert_eq(@fs.read_file(path).binary(), b"")
    assert_true(!@fs.exists(dir + "/ready") && !@fs.exists(path + ".mfl.next"))
  }
  @fs.write_file(path + ".mfl", original)
  assert_true(@host.audit(spec, path).complete)
}
