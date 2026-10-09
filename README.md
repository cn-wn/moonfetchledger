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

Core targets: wasm, wasm-gc, JavaScript and native. Host and actual validation
boundaries are recorded in `docs/validation.md`.

## Run the recovery example

Install the stable toolchain: https://www.moonbitlang.com/download/ .

```text
moon run examples/assemble
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon test --target native --deny-warn
```

The example reads a real USGS snapshot, reserves blocks, assembles in reverse
order, restores a checkpoint, damages a block, detects/refills it and verifies
the entire SHA-256. Use `moon run examples/assemble -- --input PATH` for another file. Storage is in memory;
the example runs on wasm/native and does not claim HTTP or durable disk recovery.

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

Next capability: actual HTTP/disk adapter and offline end-to-end recovery demo.
Later: backpressure and integrations driven by downstream needs. These are planned.

Apache-2.0. Data/dependency sources: `THIRD_PARTY_NOTICES.md`.
