# MoonFetchLedger

`cn-wn/moonfetchledger` is a MoonBit cross-version file update and integrity
recovery layer for existing download clients. Its [delta workflow](docs/delta-update.md)
finds verified target blocks at arbitrary offsets in old files, stages sparse
coverage, fetches gaps and delivers verified new content while preserving v1.
It also detects same-size damage and retains valid blocks during selective repair.

## Install and try

Install the [current stable MoonBit toolchain](https://www.moonbitlang.com/download/)
and a native C compiler; Windows users need an MSVC developer shell. Node 22 is
needed when running JavaScript tests. In your MoonBit application, install:

```text
moon add cn-wn/moonfetchledger@0.1.0
```

See the [0.1.0 release notes](CHANGELOG.md) for delivered features and limits.
To run a self-contained example with bundled data:

```text
git clone https://github.com/cn-wn/moonfetchledger.git MoonFetchLedger
cd MoonFetchLedger
moon update
moon run --target native examples/update-control
```

The example uses the bundled public-domain USGS data. It reconstructs a file,
prints phase progress, cancels during export readback, then resumes and verifies
byte-exact delivery with zero artifact GETs. It cleans up its temporary files.
For actual HTTP transfer and a new-process resume, run
`moon run --deny-warn scripts/delta_update_demo.mbtx`.

## Use the library in your application

For registry installation, create a `consumer` directory containing the
`moon.mod`, `moon.pkg` and `main.mbt` below; no workspace file is needed.

For **local source development**, optionally arrange the checkout and consumer
with this layout instead:

```text
workspace/
  moon.work
  MoonFetchLedger/
  consumer/
    moon.mod
    moon.pkg
    main.mbt
```

Only for local source development, put this in `workspace/moon.work` so the
dependency resolves to the checkout instead of the registry:

```moonwork
members = ["MoonFetchLedger", "consumer"]
```

Put this in `consumer/moon.mod`:

```moonmod
name = "example/mfl-first-use"
version = "0.1.0"
preferred_target = "native"

import {
  "cn-wn/moonfetchledger@0.1.0",
  "moonbitlang/async@0.22.4",
}
```

Put this in `consumer/moon.pkg`:

```moonpkg
import {
  "cn-wn/moonfetchledger/host",
  "moonbitlang/async",
  "moonbitlang/core/env",
}

pkgtype(kind: "executable")
options(supported_targets: "native")
```

Put this minimal update program in `consumer/main.mbt`:

```mbt
///|
async fn main {
  let args = @env.args()
  guard args.length() == 6 else {
    fail("expected: METADATA TRUSTED_SHA256 OLD_FILE NEW_STAGING NEW_READY")
  }
  let reference = @host.load_delta_reference(args[1], args[2])
  let result = @host.update_from_seed(
    reference,
    args[4],
    seed=args[3],
    export_to=args[5],
    checkpoint_blocks=64,
    control=@host.UpdateControl::new(on_progress=p => {
      println(p.to_json().stringify())
    }),
  )
  if !result.receive.complete || !result.exported {
    fail("update incomplete; retain staging and checkpoint for explicit resume")
  }
  println("verified and exported")
}
```

From `consumer`, run `moon update`, then:

```text
moon run --target native . -- target.delta TRUSTED_METADATA_SHA256 old.bin staging.bin ready.bin
```

The publisher supplies `target.delta` and its independently trusted SHA-256.
It must describe a reachable HTTP(S) artifact with a known length, strong ETag
and trusted whole-file digest. Choose new staging/ready paths; the old file is
preserved. [Metadata publication and delivery](docs/delta-update.md) explains how
to produce these inputs. The checked [independent application](integration/downstream/README.md)
reproduces a complete signed workflow using the real bundled fixture without
private infrastructure: `moon run --deny-warn scripts/downstream_demo.mbtx`.

After an interrupted update with a saved session, call `update_from_seed` with
`resuming=true`, omit `seed`, and retain the same metadata/staging and an unused
ready path. Use a fresh control. [Progress and cooperative cancellation](docs/update-control.md)
explains typed pauses and export cleanup. [Checkpoint batching](docs/checkpoint-batching.md)
explains the unrecorded work that may need repeating after an abrupt failure.
Use the optional [`on_preview` callback](docs/update-preview.md#decide-and-apply-without-a-second-rolling-scan)
to inspect or reject a union plan before staging and apply that same scan result.
`moon run --target native examples/preview-update` demonstrates it on real data.

| Package | Targets | Purpose |
| --- | --- | --- |
| `cn-wn/moonfetchledger` | Wasm, Wasm-GC, JS, native | Storage-independent block matching, sessions and verification |
| `cn-wn/moonfetchledger/release` | Wasm, Wasm-GC, JS, native | Publisher signature and release-policy verification |
| `cn-wn/moonfetchledger/host` | Native | Filesystem/HTTP update, audit, recovery and export |
| `cn-wn/moonfetchledger/webdav` | Native | Integration with the existing WebDAV client |

## Integrations and validation

The native [WebDAV integration](docs/webdav.md) extends the published
[q2316367743/webdav](https://github.com/q2316367743/webdav) client: the upstream
performs the original download and subsequent range requests; this project adds
verified adoption, readback, sparse recovery and final integrity checks.
[modelhub](https://github.com/QUHONGYE-gif/moonkit-modelhub) is an overlapping
download/cache project and a comparison reference; it is not integrated here.
See the [API and contribution comparison](docs/ecosystem.md). Ordinary resumable
downloads, authentication and progress are shared capabilities, not novelty claims.

Independently pinned block references also recover valid coverage when a file is
already damaged and its local checkpoint is missing. See the
[reproducible difference proof](docs/differentiation-proof.md).
Portable [signed release authorization](docs/signed-releases.md) binds a pinned
publisher key, product/channel, version and expiry to exact delta metadata.
Run `moon run --deny-warn scripts/signed_update_demo.mbtx` for the signed update CLI.

[Acceptance and local packaging](docs/acceptance.md) records reproduction commands;
[validation history](docs/validation.md) distinguishes current evidence from older
milestones. [Read-only previews](docs/update-preview.md) estimate reuse before writes.
[Measured workloads](docs/stress-matrix.md), the [paired scanner experiment](docs/measurements/probe-comparison-20261026.md)
and [process/storage fault tests](docs/fault-matrix.md) describe observations and
their limits without claiming throughput superiority or power-loss safety.

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
- [Pinned complete block references](docs/block-reference.md): publish records
  after whole-source verification and audit unmanaged damaged files without local
  checkpoints, networking or sidecar creation.
- [Native reference CLI](docs/reference-cli.md): verified source publication and
  independently pinned, checkpoint-free read-only audits with strict mode and
  descriptor-path protection; explicit new-checkpoint adoption followed by saved
  local repair, new-process resume and verified export.
- Reference-based adoption of damaged/truncated existing files: create a new
  checkpoint from actual matching blocks, preserve content and existing metadata,
  then repair through the existing client or local-backup workflow.
- [Real-server integration](integration/README.md): a separate reproducible
  WsgiDAV/Cheroot test using the published WebDAV client for PROPFIND, conditional
  ranges, checkpoint-free damage recovery and changed-version refusal.
- [Cross-version seed reuse](docs/delta-update.md): publish an authenticated target
  index, find moved blocks in an untrusted old file with rolling/SHA-256 matching,
  and stage a new sparse MFL1 session for existing receivers. The old file is
  preserved; a derived real-data v2 example demonstrates offline reconstruction.
- [Complete delta update workflow](docs/delta-update.md): bounded hash-pinned HTTP
  metadata, moved-block staging, gap downloads, explicit resume and verified
  delivery through `host.update_from_seed` and `cmd/update`. Run
  `moon run scripts/delta_update_demo.mbtx`; [signed updates](docs/signed-releases.md)
  authenticate publisher metadata using an independently provisioned public key.
- Multiple ordered old files jointly supply verified target blocks. Preview and
  update APIs expose total scan/candidate-hash budgets; signed CLI updates accept
  the same pool and limits. Exceeded limits refuse staging rather than skipping
  matches or silently downloading everything. Resume retains verified coverage.
- Verified local-file adoption: bounded storage indexing, whole-digest gating,
  new recovery checkpoint and later selective repair without changing original bytes.
- Verified export to a new ready-to-use path: source reconciliation, copied-byte
  SHA-256, synced destination readback and publication without replacing files.
- Offline selective repair from a fully verified local backup: preserve correct
  target blocks, reject changed backup reads, checkpoint every repaired block;
  [saved progress, copy budgets and cooperative pause/resume](docs/local-repair.md).
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
also checks the upstream's length-based 416 resume boundary, removes local metadata,
rebuilds 23912 valid bytes from a pinned reference without content/network writes,
and repairs only [16384,20480) while retaining the original single full download.
The fixture
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

Planned: automatic trust-anchor distribution/rotation and a browser storage
adapter, driven by downstream needs. Directory synchronization, shared chunk
caching and installed-file replacement remain outside the current delivery.
[Design and roadmap](docs/design.md). Standalone workflows require the current
stable toolchain's import frontmatter: [toolchain notes](docs/toolchain.md).

Apache-2.0. Data/dependency sources: `THIRD_PARTY_NOTICES.md`.
