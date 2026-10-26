# Process and storage failure matrix

Run in a native compiler environment:

    moon run --deny-warn scripts/fault_matrix.mbtx

The driver builds a separate native release worker. Every case uses a new owned
temporary directory and an exact copy of the public-domain USGS fixture. The
worker refuses a missing ownership marker or a different input digest. It uses
a controlled local range callback to test storage state; this is not an HTTP
traffic measurement. The scale matrix tests actual HTTP separately.

| Fault | Evidence required before success |
| --- | --- |
| Hard kill after saved block | Worker saves/syncs one block, reaches a barrier while holding the session lock, and is forcibly terminated by its owning driver. A fresh process retains 4096 bytes, reads six remaining blocks and verifies the complete file. |
| Hard kill with pending candidate | At a controlled barrier the worker writes/readbacks a second block and syncs a valid ahead-of-checkpoint candidate. After forced termination, ordinary resume refuses without mutation. Explicit recovery retains 8192 bytes and a new process reads only five remaining blocks. |
| Checkpoint installation failure | A directory occupies the next-save path after the first saved block. The second data block is written but its checkpoint cannot be installed. The old checkpoint and occupied directory survive. Removing only that owned fixture directory allows recovery from the one saved block; the unrecorded second block is fetched again. |
| Device-full boundary (Linux) | A direct sequential write to /dev/full confirms actual ENOSPC. The receiver separately refuses that nonregular output with a typed diagnostic before source reads and without changing coverage. Restoring owned empty regular staging permits completion. This is not an end-to-end ordinary-file ENOSPC test. |
| Regular kernel-file write failure (Linux) | The worker's own /proc/self/oom_score_adj has regular-file mode. A positional write of fixed nonnumeric fixture bytes returns EINVAL; the setting before/after is equal. The receiver propagates this actual I/O refusal after one source read without committing coverage, and retries successfully after restoring owned regular staging. No OOM setting is intentionally changed. |

The first two rows terminate real owned child processes with hard cancellation,
not a simulated return or a cooperative pause. Barriers make the stored state
deterministic. The pending candidate is constructed using public ledger APIs at
an explicit test window; this does not sample arbitrary instructions inside the
private checkpoint writer. Process death is not a power-loss/directory-fsync
durability guarantee, and no malicious-filesystem protection is inferred.

The publisher bytes and final whole-file digest must remain exact. Results use
MFLFAULT1 records: [tag, recoveryMode, retainedBytes, newlyReadBlocks, finalSha256].
Decimal counters refer to the controlled source callback, not network traffic.
Platforms without Linux /dev/full emit an explicit skipped record for that row;
the process and checkpoint cases still run. The kernel-file row additionally
requires /proc/self/oom_score_adj. There is no fake cross-platform ENOSPC success
and no claim to have exhausted a regular filesystem or tested power loss.
The parent cancels only process handles it created and recursively removes only
its newly owned temporary directory. No production failure hooks are added.
