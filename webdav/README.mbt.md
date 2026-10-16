# WebDAV integrity extension

The existing WebDAV client handles requests. This package adds exact object
binding and response gates, then uses the shared host receive/recovery workflow.
Only native is supported. See `docs/webdav.md` and `examples/webdav` in the repository.

```mbt check
///|
test "construct a WebDAV integrity source without a network request" {
  let spec = @ledger.ObjectSpec::new(
    "https://example.test/dav/empty",
    0L,
    "\"v1\"",
    @ledger.digest(b""),
  )
  let config : @upstream.WebdavConfig = {
    base_url: "https://example.test/dav/",
    username: None,
    password: None,
    timeout_ms: Some(5000),
    retry_on_423: None,
  }
  let source = @webdav.Source::new(spec, config, "empty")
  assert_eq(source.spec, spec)
}
```
