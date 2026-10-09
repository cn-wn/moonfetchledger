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
call `@host.repair_from_local(spec, output, backup)`; the result reports confirmed
bytes, copied blocks, retained bytes and invalidated ranges. Offline modes are
mutually exclusive; download options, including chunk size, are rejected. The
existing checkpoint determines the block layout.

The adapter takes the existing target session's exclusive cooperative lock,
verifies the entire backup before creating/writing target data or saving coverage,
reconciles actual target storage, and copies only unconfirmed blocks. Each read
is checked against the verified source index before writing, then synced, read
back, confirmed and checkpointed. The complete target is finally verified again.
Repeated repair reports zero copied blocks and preserves deterministic coverage.

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
the restored artifact. The URL deliberately has no listening server. Data and
dependency provenance remain in `THIRD_PARTY_NOTICES.md`; new code/tests are
project-authored under Apache-2.0.
