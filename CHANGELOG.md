# Release notes

## 0.1.0 — 2026-10-31

Initial release of the file update and recovery library. The 0.x
public APIs may evolve; compatibility changes will be recorded here.

### Delivered

- Cross-version file updates from one to 32 ordered old files: rolling matching,
  SHA-256 validation, moved-block reuse, read-only union previews and explicit
  scan/candidate-hash budgets. Missing target blocks use the existing receiver.
- Publisher-authenticated metadata through a pinned Ed25519 public key, product/
  channel/version/expiry policy and persistent monotonic release acceptance.
  Metadata byte pins are checked before parsing; artifact identity includes a
  trusted whole-file digest and strong ETag.
- Native HTTP and generic range receivers, plus an adapter for the published
  WebDAV client. Response validation precedes content writes; sync/readback and
  checkpoints establish recoverable coverage. Credentials remain transient and
  resource-bound. Bounded retries are opt-in; requests use configured timeouts.
- Read-only disk audits, independently pinned block references, recovery without
  a local checkpoint, selective local-backup repair, explicit interrupted-save
  recovery and verified export to a new destination while preserving source files.
- Full-update progress from release/metadata loading through scanning, reuse,
  recovery, download, verification and export. `UpdateControl` provides typed
  cooperative pauses; both update CLIs support `--progress-json` and
  `--cancel-file`. Pauses preserve resumable sessions and clean owned export
  temporaries. Current requests drain rather than being forcibly interrupted.
- Opt-in checkpoint batches of 1..1024 blocks, default 1, with a 16 MiB pending
  content flush threshold (possibly exceeded by one final block). Saved progress
  follows checkpoint installation. Unrecorded pending work is retried after
  abrupt failure. The 876-block USGS example observes 14 saved groups at 64
  blocks/batch versus 876 by default, with identical final bytes; this is not a
  throughput benchmark.
- Optional async preview approval before staging: show or reject a union plan,
  then apply that same scan result with selected-block SHA-256 rechecks. The
  initial-update CLIs provide `--plan-before-update` for a report followed by
  automatic continuation. Standalone read-only previews remain available.
- Real ordinary-file ENOSPC integration at content, checkpoint and export
  boundaries on an owned ext4 image, followed by exact new-process recovery.

### Targets and adoption

The core and `release` packages support Wasm, Wasm-GC, JavaScript and native.
Filesystem/HTTP/WebDAV adapters and update CLIs require native. Start with the
[installation and minimal API example](README.md#install-and-try), then the
[independent consumer](integration/downstream/README.md). Local workspaces are
available for source development; applications can depend on
`cn-wn/moonfetchledger@0.1.0`.

### Validation

The preview-approval revision passed strict four-target compilation, 51 tests on
each portable target and 153 actual native tests on Linux. Its
[CI run](https://github.com/cn-wn/moonfetchledger/actions/runs/41181569036) passed
Linux/macOS/Windows execution, local source-package extraction/downstream use
and real WsgiDAV integration, including a separate ordinary ext4 ENOSPC job.
Real-data examples cover pause/resume, corruption,
changed-version refusal, export cleanup and input preservation. Six Linux fault
cases exercise killed processes and documented storage/checkpoint failures.
See [validation](docs/validation.md) and [acceptance](docs/acceptance.md) for commands
and the exact limits of this evidence.

### Scope and sources

Known-length binary file objects with strong validators and independently
trusted digests are supported. Automatic trust bootstrap/key rotation, TUF and
`.zsync` interoperability, directory synchronization, shared chunk caches,
installed-file replacement, malicious filesystems and general power-loss safety
are outside 0.1.0. The Ed25519 dependency is unaudited and not constant-time;
no stronger cryptographic assurance is claimed.

Apache-2.0. Dependencies, public-domain USGS data, public test keys and conceptual
references are documented in [third-party notices](THIRD_PARTY_NOTICES.md).
