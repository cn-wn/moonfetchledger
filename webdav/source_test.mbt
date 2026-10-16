///|
test "WebDAV source checks exact object binding upstream range bounds and credential transport" {
  let empty = @ledger.digest(b"")
  let config : @upstream.WebdavConfig = {
    base_url: "https://example.test/dav/",
    username: None,
    password: None,
    timeout_ms: Some(5000),
    retry_on_423: None,
  }
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/dav/file", 2147483647L, "\"v1\"", empty,
  )
  assert_eq(@webdav.Source::new(spec, config, "file").spec, spec)
  let unicode = @ledger.ObjectSpec::new(
    "https://example.test/dav/%E4%B8%AD%20file", 0L, "\"v1\"", empty,
  )
  assert_eq(@webdav.Source::new(unicode, config, "/中 file").spec, unicode)
  let large = @ledger.ObjectSpec::new(
    spec.resource,
    2147483648L,
    spec.etag,
    empty,
  )
  for
    (identity, settings, path) in [
      (large, config, "file"),
      (spec, config, "other"),
      (spec, config, ""),
      (spec, { ..config, timeout_ms: Some(0), }, "file"),
      (spec, { ..config, timeout_ms: Some(120001), }, "file"),
      (spec, { ..config, password: Some("public-fixture-password"), }, "file"),
      (spec, { ..config, base_url: "https://example.test/dav/?x=y", }, "file"),
    ] {
    try @webdav.Source::new(identity, settings, path) catch {
      @webdav.InvalidConfig(_) => ()
      _ => fail("incorrect WebDAV preflight failure")
    } noraise {
      _ => fail("accepted invalid WebDAV binding")
    }
  }
  let http_spec = @ledger.ObjectSpec::new(
    "http://127.0.0.1:1/dav/file",
    0L,
    spec.etag,
    empty,
  )
  let auth_config = {
    ..config,
    base_url: "http://127.0.0.1:1/dav",
    username: Some("fixture"),
    password: Some("public-fixture-password"),
  }
  try @webdav.Source::new(http_spec, auth_config, "file") catch {
    @webdav.InvalidConfig(_) => ()
    _ => fail("incorrect plaintext credential refusal")
  } noraise {
    _ => fail("allowed implicit plaintext credentials")
  }
  ignore(
    @webdav.Source::new(
      http_spec,
      auth_config,
      "file",
      allow_loopback_auth=true,
    ),
  )
  for
    base in [
      "https://example.test:4294967376", "https://example.test:00443", "https://example.test:",
      "https://:443",
    ] {
    let invalid_port = @ledger.ObjectSpec::new(
      base + "/file",
      0L,
      spec.etag,
      empty,
    )
    try
      @webdav.Source::new(invalid_port, { ..config, base_url: base, }, "file")
    catch {
      @webdav.InvalidConfig(_) => ()
      _ => fail("incorrect ambiguous authority refusal")
    } noraise {
      _ => fail("silently normalized an invalid port/host")
    }
  }
  let userinfo = @ledger.ObjectSpec::new(
    "https://user@example.test/file",
    0L,
    spec.etag,
    empty,
  )
  try
    @webdav.Source::new(
      userinfo,
      { ..config, base_url: "https://user@example.test", },
      "file",
    )
  catch {
    @webdav.InvalidConfig(_) => ()
    _ => fail("incorrect userinfo refusal")
  } noraise {
    _ => fail("persisted URL credentials")
  }
}
