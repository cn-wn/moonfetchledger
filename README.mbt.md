# Checked public API example

```mbt check
///|
test {
  let bytes = b"abc"
  let object = @moonfetchledger.ObjectSpec::new(
    "https://example.test/a",
    3L,
    "\"v1\"",
    @moonfetchledger.digest(bytes),
  )
  let session = @moonfetchledger.Session::new(object, chunk_size=3)
  let lease = session.reserve_missing().unwrap()
  let prepared = session.prepare_chunk(
    lease,
    bytes,
    status=206,
    etag=object.etag,
    range=lease.range,
    total=3L,
  )
  session.commit_written(prepared, bytes)
  session.verify_complete(_ => bytes)
  assert_eq(session.confirmed_bytes(), 3L)
}
```
