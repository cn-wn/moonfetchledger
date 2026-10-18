# Checked public API example

A publisher can also provide full block records for independent file audits.
The consumer requires their separately trusted exact-byte pin and still rereads
all local storage; authentic reference records do not imply local coverage.

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
  indexer.push(bytes)
  let reference = indexer.block_reference()
  let recovered = reference.session()
  assert_eq(recovered.confirmed_bytes(), 0L)
  assert_true(recovered.reconcile_block({ start: 0L, end: 3L, }, Some(bytes)))
  recovered.finish_recovery()
  recovered.verify_complete(_ => bytes)
}
```

A publisher can distribute one identity manifest; parsing requires separately
trusted input. The native loader additionally verifies an independent byte hash.

```mbt check
///|
test {
  let object = @moonfetchledger.ObjectSpec::new(
    "https://example.test/a",
    3L,
    "\"v1\"",
    @moonfetchledger.digest(b"abc"),
  )
  let manifest = object.to_manifest()
  let restored = @moonfetchledger.ObjectSpec::from_manifest(manifest)
  assert_eq(restored, object)
  assert_eq(restored.to_manifest(), manifest)
}
```

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
