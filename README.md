# MoonFetchLedger

`cn-wn/moonfetchledger` is a reusable MoonBit library for sparse, out-of-order
HTTP download reception and verified storage recovery. It records confirmed
fixed-block coverage rather than trusting file length or a downloaded-byte count.

## Implemented

- Object identity: resource, known length, strong ETag, trusted whole-file SHA-256.
- Disjoint reservations, cancellation and session-bound opaque leases.
- Response validation before writing; readback confirmation and idempotent commits.
- Deterministic strict checkpoints; restoration distrusts recorded coverage until
  the adapter reads actual storage and reports corrupt/missing blocks.
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

Core targets: wasm, wasm-gc, JavaScript and native. Host and actual validation
boundaries are recorded in `docs/validation.md`.

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

This is a complementary receive/storage-state layer, not a replacement HTTP stack,
model hub, tus upload protocol or content-deduplication engine. We make no claim
of ecosystem uniqueness or performance superiority. API review: `docs/ecosystem.md`.

Planned: authenticated manifest integration and a browser storage
adapter, driven by downstream needs. [Design and roadmap](docs/design.md).

Apache-2.0. Data/dependency sources: `THIRD_PARTY_NOTICES.md`.
