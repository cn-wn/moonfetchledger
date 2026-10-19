///|
// Run only through scripts/wsgidav_demo.mbtx: the harness owns the loopback
// service and its disposable share. No production endpoint or credentials.
async fn main {
  let args = @env.args()
  if args.length() < 3 {
    fail("use moon run scripts/wsgidav_demo.mbtx")
  }
  let port_text = args[args.length() - 2]
  let owner = args[args.length() - 1]
  let port = @strconv.parse_int(port_text)
  if port < 1 || port > 65535 || port.to_string() != port_text {
    fail("test server requires a canonical loopback port")
  }
  let endpoint = "http://127.0.0.1:\{port}"
  let config : @upstream.WebdavConfig = {
    base_url: endpoint,
    username: None,
    password: None,
    timeout_ms: Some(5000),
    retry_on_423: Some(false),
  }
  let client = @upstream.create_webdav_client(config)
  if owner.length() != 64 {
    fail("test share requires an ownership token")
  }
  for c in owner {
    if !(('0' <= c && c <= '9') || ('a' <= c && c <= 'f')) {
      fail("test share requires a hexadecimal ownership token")
    }
  }
  // TCP readiness alone cannot rule out another process winning the port race.
  // Prove this disposable share is reachable before any artifact workflow/PUT.
  let marker = client.get_file(path="/mfl-owner-" + owner + ".txt") catch {
    _ => fail("test share ownership marker unavailable; refusing workflow")
  }
  if marker.status != 200 || marker.content != @utf8.encode(owner) {
    fail("test share ownership marker mismatch; refusing workflow")
  }
  let data = @fs.read_file("fixtures/earthquakes-2024-01-01.csv").binary()
  let digest = "dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042"
  assert_eq(@ledger.digest(data), digest)
  let remote = "/earthquakes.csv"
  let properties = client.stat(path=remote)
  assert_true(!properties.is_dir)
  assert_eq(properties.content_length, Some(28008))
  // DAV:getetag property text is not assumed to be an HTTP entity-tag field.
  let probe = client.get_file(
    path=remote,
    range=@upstream.ByteRange::from(start=0, end=0),
  )
  assert_eq(probe.status, 206)
  assert_eq(probe.content, data[0:1].to_owned())
  let range = probe.content_range.unwrap()
  assert_eq(range.first, 0)
  assert_eq(range.last, 0)
  assert_eq(range.total, Some(28008))
  let etag = probe.etag.unwrap()
  let spec = @ledger.ObjectSpec::new(endpoint + remote, 28008L, etag, digest)
  let dir = @fs.tmpdir(prefix="moonfetchledger-wsgidav-client-")
  defer @fs.rmdir(dir, recursive=true)
  let output = dir + "/installed.csv"
  client.download_to_path(path=remote, local_path=output)
  assert_eq(@fs.read_file(output).binary(), data)
  let metadata = dir + "/release.blocks.mfl"
  let pin = @host.write_block_reference(
    spec,
    "fixtures/earthquakes-2024-01-01.csv",
    metadata,
    chunk_size=4096,
  )
  let reference_bytes = @fs.read_file(metadata).binary()
  let reference = @host.load_block_reference(spec, metadata, pin)
  let file = @fs.open(output, mode=ReadWrite)
  file.write_at(b"\x00", position=8195L)
  file.sync()
  file.close()
  let damaged = @fs.read_file(output).binary()
  let audit = @host.audit_with_reference(reference, output)
  assert_eq(audit.confirmed_bytes, 23912L)
  assert_eq(audit.invalidated, [{ start: 8192L, end: 12288L, }])
  assert_eq(@fs.read_file(output).binary(), damaged)
  assert_true(!@fs.exists(output + ".mfl") && !@fs.exists(output + ".mfl.lock"))
  assert_eq(
    @host.adopt_with_reference(reference, output).to_json(),
    audit.to_json(),
  )
  assert_eq(@fs.read_file(output).binary(), damaged)
  let committed : Array[@ledger.ByteRange] = []
  let source = @dav.Source::new(spec, config, remote)
  let repaired = source.receive(output, parallel=1, on_progress=event => {
    if event.phase is BlockCommitted(range) {
      committed.push(range)
    }
  })
  assert_true(repaired.complete)
  assert_eq(repaired.recovery.retained_bytes, 23912L)
  assert_eq(repaired.downloaded_blocks, 1)
  assert_eq(committed, [{ start: 8192L, end: 12288L, }])
  assert_eq(@fs.read_file(output).binary(), data)
  assert_eq(@fs.read_file(output + ".mfl").binary(), reference_bytes)
  @host.export_verified(spec, output, dir + "/ready.csv")
  assert_eq(@fs.read_file(dir + "/ready.csv").binary(), data)
  // A genuine server version change must be refused before artifact writes.
  let changed = data + b"x"
  let _ = client.put_file(path=remote, data=changed)
  let current = client.get_file(
    path=remote,
    range=@upstream.ByteRange::from(start=0, end=0),
  )
  assert_true(current.etag != Some(etag))
  assert_eq(current.content_range.unwrap().total, Some(28009))
  try
    client.get_file(
      path=remote,
      range=@upstream.ByteRange::from(start=16384, end=20479),
      conditions=@upstream.Conditions::new(if_match=etag),
    )
  catch {
    @dav_types.WebdavError(Api(status~, ..)) => assert_eq(status, 412)
    _ => fail("expected actual server HTTP 412")
  } noraise {
    _ => fail("server accepted stale If-Match")
  }
  let file = @fs.open(output, mode=ReadWrite)
  file.write_at(b"\x00", position=16387L)
  file.sync()
  file.close()
  let stale = @fs.read_file(output).binary()
  try source.receive(output, parallel=1) catch {
    @dav.RequestFailed(_) => ()
    _ => fail("expected a sanitized stale-version refusal")
  } noraise {
    _ => fail("accepted a changed remote version")
  }
  assert_eq(@fs.read_file(output).binary(), stale)
  assert_eq(@host.audit(spec, output).confirmed_bytes, 23912L)
  assert_eq(@fs.read_file(metadata).binary(), reference_bytes)
  println(
    "WsgiDAV interoperability verified: real PROPFIND/HTTP ETag/full download, pinned recovery retaining 23912 bytes, one 4096-byte range repair/export, changed-version If-Match refusal preserving artifact bytes",
  )
}
