///|
async test "checkpoint save creates only owned temporaries and cleans a failed installation" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-checkpoint-save-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/checkpoint"
  let spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/empty",
    0L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  let session = @ledger.Session::new(spec)
  @fs.write_file(path, b"original")
  @fs.write_file(path + ".next", b"unrelated")
  try save(session, path) catch {
    _ => ()
  } noraise {
    _ => fail("truncated unrelated temporary")
  }
  assert_eq(@fs.read_file(path).binary(), b"original")
  assert_eq(@fs.read_file(path + ".next").binary(), b"unrelated")
  @fs.remove(path + ".next")
  @fs.remove(path)
  @fs.mkdir(path)
  try save(session, path) catch {
    _ => ()
  } noraise {
    _ => fail("replaced directory with checkpoint")
  }
  assert_true(!@fs.exists(path + ".next"))
  @fs.rmdir(path)
  save(session, path)
  assert_eq(@fs.read_file(path).text(), session.checkpoint())
  assert_true(!@fs.exists(path + ".next"))
}
