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
  // The target version can now reuse moved bytes from an untrusted v1.
  let v2 = b"MoonFetchLedger v2\n" +
    data[8192:16384].to_owned() +
    b"new-section\n" +
    data[:4096].to_owned() +
    data[16384:].to_owned()
  let remote_v2 = "/earthquakes-v2.bin"
  let _ = client.put_file(path=remote_v2, data=v2)
  let probe_v2 = client.get_file(
    path=remote_v2,
    range=@upstream.ByteRange::from(start=0, end=0),
  )
  assert_eq(probe_v2.status, 206)
  assert_eq(probe_v2.content_range.unwrap().total, Some(v2.length()))
  let spec_v2 = @ledger.ObjectSpec::new(
    endpoint + remote_v2,
    v2.length().to_int64(),
    probe_v2.etag.unwrap(),
    @ledger.digest(v2),
  )
  let publisher_v2 = dir + "/publisher-v2"
  let seed_v1 = dir + "/seed-v1"
  let staged_v2 = dir + "/staged-v2"
  @fs.write_file(publisher_v2, v2)
  @fs.write_file(seed_v1, data)
  let old_v1 = @fs.open(seed_v1, mode=ReadWrite)
  old_v1.write_at(b"\x00", position=12000L)
  old_v1.close()
  let old_bytes = @fs.read_file(seed_v1).binary()
  let delta_path = dir + "/v2.delta"
  let delta_pin = @host.write_delta_reference(
    spec_v2,
    publisher_v2,
    delta_path,
    chunk_size=4096,
  )
  let delta_bytes = @fs.read_file(delta_path).binary()
  let _ = client.put_file(path="/v2.delta", data=delta_bytes)
  let delta = @host.fetch_delta_reference(endpoint + "/v2.delta", delta_pin)
  let seeded = @host.reuse_from_seed(delta, seed_v1, staged_v2)
  assert_eq(seeded.reused_bytes, 11655L)
  let ranges_v2 : Array[@ledger.ByteRange] = []
  let collect = async fn(event : @host.DownloadProgress) -> Unit {
    if event.phase is BlockCommitted(range) {
      ignore(@ledger.restore(@fs.read_file(staged_v2 + ".mfl").text(), spec_v2))
      ranges_v2.push(range)
    }
  }
  let source_v2 = @dav.Source::new(spec_v2, config, remote_v2)
  let paused_v2 = source_v2.receive(
    staged_v2,
    parallel=1,
    stop_after_blocks=1,
    on_progress=collect,
  )
  assert_true(!paused_v2.complete)
  assert_eq(paused_v2.confirmed_bytes, 15751L)
  let resumed_v2 = @dav.Source::new(spec_v2, config, remote_v2).receive(
    staged_v2,
    parallel=1,
    on_progress=collect,
  )
  assert_true(resumed_v2.complete)
  assert_eq(resumed_v2.downloaded_blocks, 2)
  assert_eq(ranges_v2, [
    { start: 0L, end: 4096L, },
    { start: 8192L, end: 12288L, },
    { start: 12288L, end: 16384L, },
  ])
  @host.export_verified(spec_v2, staged_v2, dir + "/ready-v2")
  assert_eq(@fs.read_file(dir + "/ready-v2").binary(), v2)
  assert_eq(@fs.read_file(seed_v1).binary(), old_bytes)
  assert_eq(@fs.read_file(delta_path).binary(), delta_bytes)
  println(
    "WsgiDAV cross-version update verified: real publisher metadata GET, moved-block reuse=11655, missing=12288 fetched through published WebDAV client across pause/reopen, preserved v1 and verified v2 delivery",
  )
}
