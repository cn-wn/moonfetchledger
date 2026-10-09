# Adopting an existing local artifact

An artifact fetched by another program can enter MoonFetchLedger without being
downloaded again. Supply independently trusted URL/resource, length, strong ETag
and SHA-256, and call `host.adopt(spec, output, chunk_size=65536)` (native), or:

```text
moon run --target native cmd/fetch -- --adopt --url URL --output PATH --length N --etag QUOTED_ETAG --sha256 HEX --chunk-size 65536
moon run --target native cmd/fetch -- --audit --url URL --output PATH --length N --etag QUOTED_ETAG --sha256 HEX
moon run scripts/local_storage_demo.mbtx
```

Adoption reads an existing regular file through a read-only handle, holds the
session's exclusive cooperative lock and requires exact length. The portable
StorageIndexer reads aligned blocks, checks lengths before advancing, computes
per-block hashes and the entire digest, and exposes a Session only after the
trusted whole digest matches. It does not invent HTTP 206 responses or claim to
have checked the remote ETag. Identity must describe the representation whose
digest was obtained independently; adoption never contacts its resource.

Only then does the host write a new `.mfl.next`, sync and rename it to `.mfl`
without replacement. Existing checkpoints or temporary files are errors and are
preserved. A failed digest or length check creates no checkpoint and changes no
source bytes. A newly created `.mfl.lock` may remain. Ordinary save failures clean
up only the temporary file this invocation created; interrupted processes can
leave temporary data, which must be inspected before another adoption. There is
no directory-fsync or power-loss guarantee. Use a trusted directory without
external writers; locks coordinate cooperating programs.

Retain output, `.mfl` and `.mfl.lock` afterward. Normal audit/download restoration
reads recorded blocks again; adoption is not permanent permission to trust a cache.
If content is damaged later, the usual workflow refetches only missing/damaged
blocks. A complete adopted file can reopen through download without any HTTP
request. Arbitrary partial files are not adopted; this workflow cannot prove their
unrecorded coverage or authenticity from file length alone.

Custom portable/asynchronous storage adapters use `StorageIndexer.new`,
`next_range`, `push` and `finish`. Supply exactly each next half-open range. A short
or extra read is rejected without advancing state; incomplete indexing and wrong
digests never return a Session. Successful repeated finish returns a fresh session
with a deterministic MFL1 checkpoint, compatible with normal recovery.

The demo uses the unchanged public-domain USGS fixture documented in
`fixtures/README.md`. New implementation and test data are project-authored;
existing SHA-256 and I/O dependencies retain the sources/licenses recorded in
`THIRD_PARTY_NOTICES.md`.
