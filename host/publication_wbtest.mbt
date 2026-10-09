///|
async test "publication cleans owned partial files and never replaces a racing destination" {
  let dir = @fs.tmpdir(prefix="moonfetchledger-publication-")
  defer @fs.rmdir(dir, recursive=true)
  let destination = dir + "/ready"
  try
    publish_new(destination, file => {
      file.write("partial")
      raise InvalidInput("injected storage workflow failure")
    })
  catch {
    InvalidInput(_) => ()
    _ => fail("incorrect propagated writer failure")
  } noraise {
    _ => fail("published partial writer output")
  }
  assert_true(!@fs.exists(destination) && !@fs.exists(destination + ".next"))
  try
    publish_new(destination, file => {
      file.write("verified")
      @fs.write_file(destination, b"racing owner", create_mode=CreateNew)
    })
  catch {
    _ => ()
  } noraise {
    _ => fail("replaced racing destination")
  }
  assert_eq(@fs.read_file(destination).binary(), b"racing owner")
  assert_true(!@fs.exists(destination + ".next"))
  @fs.remove(destination)
  @fs.write_file(destination + ".next", b"unrelated")
  let mut invoked = false
  try publish_new(destination, _ => invoked = true) catch {
    _ => ()
  } noraise {
    _ => fail("used someone else's temporary file")
  }
  assert_true(!invoked)
  assert_eq(@fs.read_file(destination + ".next").binary(), b"unrelated")
  @fs.remove(destination + ".next")
  publish_new(destination, file => file.write("recovered"))
  assert_eq(@fs.read_file(destination).text(), "recovered")
}
