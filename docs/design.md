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
- Session.unconfirmed_ranges projects sorted/coalesced gaps without mutations;
  host.audit inspects retained disk files without network or content writes and
  requires whole-file SHA-256 success before reporting completion. Its report
  serializes sizes/offsets as decimal strings, independently of checkpoint schema.
- StorageIndexer.new/next_range/push/finish admits existing complete storage only
  after the trusted whole digest matches. host.adopt creates a new checkpoint
  for a regular local file without HTTP metadata fabrication or source writes.
- host.export_verified copies only complete reconciled coverage, checks the digest
  during copy and after synced destination readback, and publishes to a new path
  without replacing existing files. The source session remains available.
- StorageIndexer.prepare_repair admits local block copies only after whole-source
  verification. host.repair_from_local retains valid target coverage and repairs
  missing/damaged blocks from a complete backup without network requests.
- host.download's optional on_progress observer receives saved recovery/block
  snapshots and pause/verified completion events. Observer failures preserve saved
  progress for restart; the CLI can emit deterministic MFLPROGRESS1 JSON lines.
- ObjectSpec.to_manifest/from_manifest serialize exact release identity. Native
  write_manifest/load_manifest publish a new file and verify an independent byte
  hash before parsing. The CLI uses the pinned identity in every artifact mode.

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
  retries for transient HTTP status and request timeout, read-only disk audit
  with coalesced gap reporting and deterministic JSON export.
- Implemented: verified local-file indexing/adoption and offline cached-file reuse.
- Implemented: verified export from complete retained artifacts to a new consumer
  path with failure cleanup and no-replacement publication.
- Implemented: offline local-backup repair with source revalidation, readback,
  selective copying and durable per-block recovery checkpoints.
- Implemented: serialized download progress and callback-error restart behavior.
- Implemented: cooperative pause intent, draining current batches and resuming
  saved coverage, with completion taking precedence and errors still propagating.
- Implemented: transient resource-bound Bearer authentication, environment-only
  CLI credential input, rotation/resume, immediate 401/403 refusal and no redirects.
- Implemented: pinned release identity publication/loading, strict schema and byte
  bounds, no identity overrides, download/resume and complete offline integration.
- Planned: signed release metadata integration beyond independent SHA-256 pins.
- Planned: independent browser storage adapter with the same receive contract;
  versioned checkpoint migrations only when a concrete schema extension is needed.

A general HTTP stack, Range toolkit, model hub, upload protocol, content-defined
deduplication or distributed mirroring is outside this project's boundary.
