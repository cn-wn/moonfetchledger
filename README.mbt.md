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
  assert_true(session.unconfirmed_ranges().is_empty())
  session.verify_complete(_ => bytes)
  assert_eq(session.confirmed_bytes(), 3L)
}
```

An existing storage adapter can index complete local content without HTTP metadata:

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
  let indexer = @moonfetchledger.StorageIndexer::new(object, chunk_size=3)
  assert_eq(indexer.next_range(), Some({ start: 0L, end: 3L, }))
  indexer.push(bytes)
  let session = indexer.finish()
  assert_eq(session.confirmed_bytes(), 3L)
  assert_true(session.unconfirmed_ranges().is_empty())
}
```
