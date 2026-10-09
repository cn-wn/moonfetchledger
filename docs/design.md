# Effective boundary

## Users and complete workflows

1. A MoonBit artifact updater downloads a versioned dataset or model file from a
   range-enabled origin. It receives URL, length, strong ETag and SHA-256 from a
   trusted release manifest, constructs ObjectSpec, reserves separate blocks,
   receives them concurrently, confirms actual readback, and verifies the whole
   file before activating it. A 200 fallback or changed version is a diagnostic,
   never an implicit append to old data.
2. A command-line data collector runs with intermittent connectivity. It retains
   output, checkpoint and lock sidecar. On another invocation it restores exactly
   the same identity, reads all recorded blocks from disk, and fetches only missing
   or damaged blocks. A caller-selected block budget permits a controlled pause.
3. A browser application stores blocks in its own asynchronous storage backend.
   It uses the portable core's opaque leases and prepared chunks, persists MFL1
   after successful write/readback, reconciles storage on restart and feeds the
   streaming verifier. Browser storage/network adapters are downstream work;
   the native reference adapter is not advertised as a browser implementation.

These users otherwise recreate sparse coverage, stale-request protection,
response/version validation, crash-state reconciliation and integrity checks.

## Minimal public boundary

- ObjectSpec::new and digest describe a single known immutable representation.
- Session::new, reserve_missing/release, prepare_chunk/commit_written implement
  the receive/write/readback transition. ByteRange is half-open.
- checkpoint/restore, recovery_ranges/reconcile_block/finish_recovery implement
  persisted-state distrust and explicit repair.
- verifier's next_range/push/finish permits bounded asynchronous verification;
  verify_complete supports synchronous storage.
- host.download is the optional native HTTP/filesystem reference integration.
  It returns completion, actual confirmed bytes, fetched blocks, retained bytes
  and invalidated ranges. Its errors remain distinct from LedgerError/I/O errors.

The generated interface files are the exact API source of truth. Session changes
must be serialized; parallel leases do not provide OS-thread synchronization.

## Inputs, correctness and exclusions

Known Int64 length, quoted strong ETag, trusted lowercase SHA-256, aligned fixed
blocks 1..4MiB and at most 100000 blocks. Empty and short-final objects are valid.
Core runs on wasm, wasm-gc, js and native; the reference host uses native async I/O.

Reject unsupported schema fields, versions, duplicate/unsorted block records,
noncanonical/overflowing decimals, inconsistent identities, encoded or multipart
responses, unknown lengths and weak validators. Never silently trim file contents,
reuse old capabilities, trust file length, or equate coverage with final integrity.
I/O errors propagate; no error turns into a successful completion. Checkpoints are
unsigned and require trusted storage. Cooperative locks do not protect against an
external malicious writer. No power-loss or filesystem durability guarantee.

The first independently usable slice is the portable reception/recovery library,
its checked public API example and real-data assembly. The second adds a generic
native CLI and an offline HTTP/disk workflow. Both have boundary tests and generated
interfaces. Evaluators require only the public toolchain, node and a C compiler;
the demo serves the bundled public-domain USGS snapshot over loopback.

## Coherent capability roadmap

- Implemented: object-bound sparse receipt and storage reconciliation, all core
  target tests, native host/CLI, offline selective-repair workflow, bounded block
  retries for transient HTTP status and request timeout.
- Planned: cancellation reporting informed by real clients; authenticated
  release-manifest integrations.
- Planned: independent browser storage adapter with the same receive contract;
  versioned checkpoint migrations only when a concrete schema extension is needed.

A general HTTP stack, Range toolkit, model hub, upload protocol, content-defined
deduplication or distributed mirroring is outside this project's boundary.
