///|
async test "manifest publication preserves existing files and pinned loading is read only" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-manifest-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/release.json"
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/雪",
    9007199254740993L,
    "\"v1\"",
    @ledger.digest(b"abc"),
  )
  let pin = @host.write_manifest(spec, path)
  let original = @fs.read_file(path).binary()
  assert_eq(pin, @ledger.digest(original))
  assert_eq(@fs.read_file(path).text(), spec.to_manifest())
  assert_eq(@host.load_manifest(path, pin), spec)
  assert_eq(@fs.read_file(path).binary(), original)
  assert_true(!@fs.exists(path + ".next"))
  try @host.write_manifest(spec, path) catch {
    _ => ()
  } noraise {
    _ => fail("replaced an existing manifest")
  }
  assert_eq(@fs.read_file(path).binary(), original)
  assert_true(!@fs.exists(path + ".next"))
  let other = dir + "/other.json"
  @fs.write_file(other + ".next", b"unrelated temporary")
  try @host.write_manifest(spec, other) catch {
    _ => ()
  } noraise {
    _ => fail("replaced an unrelated temporary")
  }
  assert_eq(@fs.read_file(other + ".next").binary(), b"unrelated temporary")
  assert_true(!@fs.exists(other))
  for
    bad_pin in [
      "",
      "a".repeat(63),
      "A".repeat(64),
      "g".repeat(64),
      @ledger.digest(b"wrong"),
    ] {
    try @host.load_manifest(path, bad_pin) catch {
      @host.InvalidInput(_) => ()
      _ => fail("incorrect manifest pin diagnostic")
    } noraise {
      _ => fail("accepted an incorrect manifest pin")
    }
    assert_eq(@fs.read_file(path).binary(), original)
  }
  @fs.write_file(path, b"malformed JSON")
  try @host.load_manifest(path, pin) catch {
    @host.InvalidInput(message) => assert_true(message.contains("trusted pin"))
    _ => fail("parsed manifest before checking trusted digest")
  } noraise {
    _ => fail("accepted changed manifest")
  }
  @fs.write_file(path, original)
  assert_eq(@host.load_manifest(path, pin), spec)
}

///|
async test "manifest input bounds and strict encoding reject data rather than replacing it" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-manifest-bounds-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/release.json"
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/a",
    0L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  let text = spec.to_manifest()
  @fs.write_file(path, text + " ".repeat(65536 - text.length()))
  let pin = @ledger.digest(@fs.read_file(path).binary())
  assert_eq(@host.load_manifest(path, pin), spec)
  @fs.write_file(path, text + " ".repeat(65537 - text.length()))
  try @host.load_manifest(path, pin) catch {
    @host.InvalidInput(message) => assert_true(message.contains("65536 bytes"))
    _ => fail("incorrect bounded input diagnostic")
  } noraise {
    _ => fail("accepted oversized manifest")
  }
  let malformed = b"[\"MFLARTIFACT1\",\"http://example.test/\xff\",\"0\",\"\\\"v1\\\"\",\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"]"
  @fs.write_file(path, malformed)
  try @host.load_manifest(path, @ledger.digest(malformed)) catch {
    @host.InvalidInput(message) => assert_true(message.contains("strict UTF-8"))
    _ => fail("incorrect strict UTF-8 diagnostic")
  } noraise {
    _ => fail("silently replaced malformed UTF-8")
  }
  @fs.write_file(path, b"[\"MFLARTIFACT2\"]")
  let pin = @ledger.digest(@fs.read_file(path).binary())
  try @host.load_manifest(path, pin) catch {
    @ledger.InvalidManifest(_) => ()
    _ => fail("incorrect manifest schema diagnostic")
  } noraise {
    _ => fail("accepted unsupported manifest version")
  }
  try @host.load_manifest(dir, pin) catch {
    @host.InvalidInput(_) => ()
    _ => fail("incorrect non-regular input diagnostic")
  } noraise {
    _ => fail("accepted a directory as manifest")
  }
  @fs.write_file(path, text)
  assert_eq(
    @host.load_manifest(path, @ledger.digest(@fs.read_file(path).binary())),
    spec,
  )
}
