///|
async test "receiver refuses a nonregular opened output before source reads and preserves resumability" {
  if !@fs.exists("/dev/full") {
    return
  }
  let dir = @fs.tmpdir(prefix="mfl-output-kind-")
  defer @fs.rmdir(dir, recursive=true)
  let data = b"abcDEF"
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/kind",
    6L,
    "\"v1\"",
    @ledger.digest(data),
  )
  let output = dir + "/staging"
  let fetch : async (@ledger.ByteRange) -> @host.ReceivedBlock = range => @host.ReceivedBlock::{
    bytes: data[range.start.to_int():range.end.to_int()].to_owned(),
    status: 206,
    etag: spec.etag,
    range,
    total: spec.length,
    content_encoding: "identity",
  }
  ignore(
    @host.receive_from(
      spec,
      output,
      chunk_size=3,
      stop_after_blocks=0,
      fetch_range=fetch,
    ),
  )
  let saved = @fs.read_file(output + ".mfl").binary()
  @fs.write_file(output + ".mfl.lock", b"preserve lock contents")
  @fs.remove(output)
  @fs.symlink(target="/dev/full", output)
  let mut calls = 0
  try
    @host.receive_from(spec, output, chunk_size=3, fetch_range=range => {
      calls += 1
      fetch(range)
    })
  catch {
    @host.InvalidInput(message) => assert_true(message.contains("regular file"))
    _ => fail("unsupported output kind did not return a diagnostic")
  } noraise {
    _ => fail("accepted nonregular receiver output")
  }
  assert_eq(calls, 0)
  assert_eq(@fs.kind(output, follow_symlink=false), SymLink)
  assert_eq(@fs.read_file(output + ".mfl").binary(), saved)
  assert_eq(
    @fs.read_file(output + ".mfl.lock").binary(),
    b"preserve lock contents",
  )
  @fs.remove(output)
  @fs.write_file(output, b"", create_mode=CreateNew)
  assert_true(
    @host.receive_from(spec, output, chunk_size=3, fetch_range=fetch).complete,
  )
  assert_eq(@fs.read_file(output).binary(), data)
}
