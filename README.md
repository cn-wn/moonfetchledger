# MoonFetchLedger

`cn-wn/moonfetchledger` is a MoonBit block-integrity audit and repair layer for
existing download clients. It reconciles actual fixed-block coverage, detects
same-size content damage and preserves valid blocks during selective repair.

The native [WebDAV integration](docs/webdav.md) extends the published
[q2316367743/webdav](https://github.com/q2316367743/webdav) client: the upstream
performs the original download and subsequent range requests; this project adds
verified adoption, readback, sparse recovery and final integrity checks.
[modelhub](https://github.com/QUHONGYE-gif/moonkit-modelhub) is an overlapping
download/cache project and a comparison reference; it is not integrated here.
See the [API and contribution comparison](docs/ecosystem.md). Ordinary resumable
downloads, authentication and progress are shared capabilities, not novelty claims.

## Implemented

- Object identity: resource, known length, strong ETag, trusted whole-file SHA-256.
- Disjoint reservations, cancellation and session-bound opaque leases.
- Response validation before writing; readback confirmation and idempotent commits.
- Deterministic strict checkpoints; restoration distrusts recorded coverage until
  the adapter reads actual storage and reports corrupt/missing blocks.
- All native checkpoint readers use regular files, a 16M-byte input cap, bounded
  same-handle reads and strict UTF-8/schema validation; rejected inputs are retained.
- Bounded-memory whole-file verification, including asynchronous adapter support.
- Blocks of 1..4194304 bytes, at most 100000 blocks, short final blocks and empty
  objects. Int64 offsets never pass through floating-point serialization.
- Native HTTP/filesystem adapter and generic CLI: cooperative file lock, bounded
  parallel requests, synced write/readback, replace-on-save checkpoints and repair.
- Opt-in bounded retries for 429/503 and request timeouts, with validated wait hints;
  version, representation and storage errors still fail immediately.
- Offline native audit and deterministic JSON reports: actual disk readback,
  corrupt/missing block detection, coalesced gap planning and final integrity check.
- Verified local-file adoption: bounded storage indexing, whole-digest gating,
  new recovery checkpoint and later selective repair without changing original bytes.
- Verified export to a new ready-to-use path: source reconciliation, copied-byte
  SHA-256, synced destination readback and publication without replacing files.
- Offline selective repair from a fully verified local backup: preserve correct
  target blocks, reject changed backup reads, checkpoint every repaired block.
- Serialized asynchronous download progress after saved coverage, with verified
  completion events and opt-in deterministic CLI JSON lines.
- Cooperative pause intent: drain the current batch, save it, return resumable
  incomplete coverage and resume with a fresh signal without refetching valid blocks.
- Transient resource-bound Bearer credentials for private artifacts, environment
  input in the CLI and credential rotation without changing recovery identity.
- Pinned release identity manifests: deterministic publication, hash-before-parse
  bounded loading and the same manifest for download, resume and offline operations.
- Explicit interrupted-checkpoint recovery: preserve saved temporaries, validate
  actual blocks and promote a candidate only without losing valid recorded coverage.
- Native `host.receive_from` shares storage recovery with external range sources.
- WebDAV `Source` composes the upstream `get_file` and transport extension APIs:
  exact object binding, response gates and bounded block consumption before writes.

Core targets: wasm, wasm-gc, JavaScript and native. Host and actual validation
boundaries are recorded in `docs/validation.md`.

## Extend an existing WebDAV download

```text
moon update
moon run --target native examples/webdav
```

The published client uploads/downloads the real USGS fixture. The ledger adopts
it using an independent trusted digest, detects one changed byte without network,
retains 23912 of 28008 bytes, and repairs just that block through WebDAV. It also
checks encoded-response refusal, two nonadjacent bad blocks across pause/reopen,
verified export and zero-fetch reuse after the origin stops. The loopback fixture
implements only PUT/GET/OPTIONS; vendor WebDAV server compatibility is not claimed.

## Run the recovery example

Install the stable toolchain: https://www.moonbitlang.com/download/ .

```text
moon update
moon run --target wasm examples/assemble
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn
```

The example reads a real USGS snapshot, reserves blocks, assembles in reverse
order, restores a checkpoint, damages a block, detects/refills it and verifies
the entire SHA-256. Use `moon run --target wasm examples/assemble -- --input PATH` for another file. Storage is in memory;
the example runs on wasm/native and does not claim HTTP or durable disk recovery.

For real HTTP and disk recovery with independent downloader processes:

```text
moon run scripts/recovery_demo.mbtx
moon run --target native cmd/fetch -- --help
```

The offline demo serves the bundled data, pauses, damages a confirmed disk block,
retains correct blocks, refetches only missing/damaged blocks and verifies all
final bytes. It also tests bad-response refusal and successful retry. See
[the end-to-end workflow](docs/recovery-demo.md) for commands and exact boundaries.
See [bounded retry behavior](docs/retry.md) for CLI options, supported failures
and explicit wait-hint limitations.
Use [offline audit](docs/audit.md) to inspect retained files without downloading
or rewriting them: `cmd/fetch -- --audit` with the same required identity options.
Use [local adoption](docs/local-storage.md) to register an existing file with
`--adopt`. Run `moon run scripts/local_storage_demo.mbtx` for a real-data example.
Use [verified export](docs/export.md) with `--export-to NEW_PATH` to deliver a
complete artifact while retaining its recovery session.
Use [offline local repair](docs/local-repair.md) with `--repair-from BACKUP` when
the origin is unavailable and a complete trusted copy exists locally.
Use [download progress](docs/progress.md) via `on_progress` or CLI `--progress`
to observe saved blocks, pauses and verified completion.
Use [controlled pause](docs/pause.md) for application-driven pause/resume;
`moon run --target native examples/controlled` demonstrates it with real data.
Use [authenticated download](docs/auth.md) with `--bearer-env VARIABLE_NAME`;
`moon run scripts/auth_demo.mbtx` verifies credential rotation and recovery offline.
Use [pinned manifests](docs/manifest.md) with `--manifest FILE --manifest-sha256 HEX`
instead of the four inline identity arguments. `moon run scripts/manifest_demo.mbtx`
verifies publication, authenticated resume and stopped-origin offline operations.
Use [interrupted checkpoint recovery](docs/checkpoint-recovery.md) when `.mfl.next`
remains after a failed save: `--recover-checkpoint` validates it offline before
normal resume. `moon run scripts/checkpoint_recovery_demo.mbtx` demonstrates it.

## Integration contract

1. Construct `ObjectSpec::new(resource, length, etag, sha256)` and `Session::new`.
2. `reserve_missing` returns a session-bound lease with range `[start,end)`.
3. Fetch the range. Supply the actual status, ETag, encoding, parsed Content-Range
   and body to `prepare_chunk` before writing.
4. Write at that offset, sync as needed, read the offset back, `commit_written`.
5. Persist `checkpoint()`. `restore` requires the same identity. Read every
   `recovery_ranges` entry, call `reconcile_block`, report invalidated ranges,
   then `finish_recovery`. None means absent/truncated data; propagate I/O errors.
6. `verifier` returns `next_range/push/finish` for asynchronous reads;
   `verify_complete` is its synchronous callback convenience.
7. `unconfirmed_ranges` returns a fresh coalesced coverage projection, including
   outstanding reservations, after recovery finishes. It does not reserve requests.

Serialize session mutations. Separate leases permit concurrent requests, not
unsynchronized OS-thread mutation. Readback depends on an honest storage adapter;
it does not prove physical-media durability. ETags identify versions, not content
authenticity. Obtain the expected SHA-256 from an independently trusted source.

## Checkpoint schema

MFL1 is an exact seven-element JSON array:

```text
["MFL1",resource,lengthDecimal,etag,sha256,chunkSizeDecimal,[[blockIndexDecimal,sha256],...]]
```

Records are sorted, unique and bounded. Decimal strings are canonical. Unknown
versions, extra fields, malformed records and identity changes are rejected,
not discarded. Outstanding reservations are not persisted. Checkpoints are
unsigned and must be stored in a trusted location. Whole-file verification remains
mandatory after recovery.

## Scope

Fixed aligned blocks for one HTTP object. Unknown lengths, weak/no validators,
encoded representations, multipart ranges and mirror merging are unsupported.
Full 200 responses or version changes require explicit restart.

This is a complementary receive/storage-state layer. The earlier native HTTP CLI
remains an optional reference adapter and is not the differentiated contribution.
WebDAV operations, model discovery/cache layout, tus uploads and content-defined
deduplication belong to their respective upstream projects. We make no claim of
ecosystem uniqueness or performance superiority. API review: `docs/ecosystem.md`.

Planned: signed release metadata integration and a browser storage
adapter, driven by downstream needs. [Design and roadmap](docs/design.md).

Apache-2.0. Data/dependency sources: `THIRD_PARTY_NOTICES.md`.
