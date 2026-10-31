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
| Hard kill during an opted-in batch | With batches of four, six blocks are written but only the first four are checkpointed. The driver kills the worker before fetching the seventh. A new process retains 16384 bytes and fetches three blocks, including the two unrecorded writes. |
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

## Ordinary filesystem ENOSPC and recovery (Linux)

```text
moon run --deny-warn scripts/filesystem_faults.mbtx
```

This separate integration gate requires Linux, `mkfs.ext4`, `mount`, `umount`,
`truncate`, and root or noninteractive sudo. CI runs it in an Ubuntu job. It
creates a private 16 MiB image, mounts ext4 without a journal or delayed
allocation, and fills only that image with synced ordinary-file writes until
the kernel returns ENOSPC. It does not fill the host filesystem. All output,
checkpoint and export paths are ordinary files on the image.

| Failure boundary | Recovery after removing only the owned filler |
| --- | --- |
| First content write | Prior empty checkpoint remains; a new process retains 0 bytes and receives seven blocks. |
| Replacing the checkpoint during reconciliation | No additional source fetch; old checkpoint and first 4096 bytes remain. A new process retains that block and receives six. |
| Exporting verified staging | Failed private export is removed, destination absent, staging and checkpoint unchanged. A new process retains all 28008 bytes and exports with zero new reads. |

Every failure must be the actual Linux OSError errno 28. Each fresh receiver
process compares the full USGS bytes and SHA-256, checks the publisher was not
modified, and emits an MFLFILESYSTEM1 receipt with retained bytes and new reads.
The driver unmounts before removing its owned directory; an unmount failure
retains the fixture for inspection. This establishes these ENOSPC boundaries,
not arbitrary I/O errors, inode exhaustion, filesystem corruption or power-loss
durability. The existing portable process-failure gate remains separate.
