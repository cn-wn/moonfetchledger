# Offline repair from a local backup

Use this workflow when an installed dataset is damaged and a complete copy is
available on removable media or in a local cache. No origin access is necessary.
Keep the target's existing `.mfl` and `.mfl.lock`; a missing target can be rebuilt.

```text
moon run --target native cmd/fetch -- --url https://example.test/data \
  --output retained.bin --length 7 --etag '"v1"' --sha256 TRUSTED_HEX \
  --repair-from backup.bin
```

Replace the illustrative identity with actual trusted release metadata. In MoonBit,
call `@host.repair_from_local(spec, output, backup)`; the result reports `complete`,
confirmed bytes, copied blocks, retained bytes and invalidated ranges. Existing
three-argument calls still perform complete repair. Offline modes are mutually
exclusive; only `--stop-after-blocks N` and `--progress` are accepted repair controls.
Other download options, including chunk size, are rejected. The existing checkpoint
determines the block layout.

The adapter takes the existing target session's exclusive cooperative lock,
verifies the entire backup before creating/writing target data or saving coverage,
reconciles actual target storage, and copies only unconfirmed blocks. Each read
is checked against the verified source index before writing, then synced, read
back, confirmed and checkpointed. The complete target is finally verified again.
Repeated repair reports zero copied blocks and preserves deterministic coverage.

## Pause large offline repairs and resume saved work

```moonbit
let signal = @ledger.PauseSignal::new()
let first = @host.repair_from_local(spec, "retained.bin", "backup.bin",
  pause_signal=signal,
  on_progress=event => {
    println(event.to_json().stringify())
    if event.phase is @host.BlockCopied(_) { signal.request_pause() }
  })
// first.complete=false when more blocks remain. Keep all session files.
let resumed = @host.repair_from_local(spec, "retained.bin", "backup.bin")
```

For a finite copy budget, pass `stop_after_blocks=N`, or use the CLI:

```text
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output retained.bin --repair-from backup.bin --stop-after-blocks 1 --progress
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output retained.bin --repair-from backup.bin --progress
```

Pause intent is checked before reserving each block; a copy already underway is
validated, synced, read back and checkpointed before stopping. Reusing a requested
signal performs no new copies; resume with a fresh signal or omit it. Zero budgets
are allowed; negative budgets fail before file operations. Completion takes
precedence when all blocks already verify, including empty artifacts.

The backup is always fully hashed **before** pause handling, notifications or
target writes. Even a zero budget or pre-requested signal refuses an invalid
backup. Pausing does not interrupt that verification pass; every invocation
rehashes the backup. Verification cost remains proportional to backup size.

`LocalRepairProgress` is a separate immutable snapshot with `phase`, `total_bytes`,
`confirmed_bytes` and invocation-local `repaired_blocks`. `Recovered` follows saved
target reconciliation, `BlockCopied(range)` follows saved readback confirmation,
and the final phase is `Paused` or `Complete`. `Complete` requires final whole-target
SHA-256 verification. Callbacks run serially under the target's exclusive lock;
do not recursively call locking host operations on that target. A callback error
propagates, releases resources and retains already saved blocks for the next call.

`--progress` emits deterministic JSON lines before the normal summary:
`["MFLREPAIR1",phase,total,confirmed,copiedBlocks,rangeOrNull]`. Counts and half-open
range bounds are decimal strings; phase is `recovered`, `block`, `paused` or
`complete`. A paused summary starts `repair-paused:` and a verified complete
summary retains `repaired:`. Graceful pause exits successfully; inspect the report
or summary to distinguish it from completion. Normal download progress remains
MFLPROGRESS1. The checkpoint format is unchanged.

`StorageIndexer.prepare_repair(target, lease, bytes)` exposes the same portable
contract to downstream storage adapters, without fabricated HTTP responses. It
requires completed whole-source verification and matching identity/block layout;
changed reads, short reads and foreign leases are errors. Rejected reads can be
corrected without advancing coverage.

Backup length/hash, malformed/foreign checkpoints, extra target bytes, aliases of
target session paths, existing checkpoint temporary files and competing writers
are rejected. I/O failures propagate. After a failure during copying, already
saved blocks remain recoverable; restart using the same metadata. This is a
bounded-memory, single-backup workflow, not merging fragments or trusting backup
ETags. Use trusted directories and a stable backup. Cooperative locks and hashing
do not provide a power-loss guarantee or defend against malicious filesystem
substitution. The backup is opened read-only; source access timestamps may change.

Run `moon run scripts/local_storage_demo.mbtx`. It adopts the bundled USGS
snapshot, damages a confirmed block, refuses export, repairs exactly that block
from a separate backup, repeats repair with zero copies, and successfully exports
the restored artifact. It then damages two nonadjacent blocks, copies just one,
checks saved MFLREPAIR1 JSON, audits the remaining gap, resumes retaining 23912
bytes and verifies zero-copy complete reopening with a zero budget. Invalid control
options preserve target/checkpoint bytes. The URL has no listening server. Data and
dependency provenance remain in `THIRD_PARTY_NOTICES.md`; new code/tests are
project-authored under Apache-2.0.
