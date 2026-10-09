# Download progress after saved coverage

An updater can attach an asynchronous observer to the native adapter:

```moonbit
async fn fetch_with_progress(spec : @ledger.ObjectSpec, path : String) -> Unit {
  let report = @host.download(spec, path, on_progress=event => {
    println(event.to_json().stringify())
  })
  if !report.complete { println("paused; retain the output and both sidecars") }
}
```

Use the generated host interface for imports. Existing calls can omit
`on_progress`. The observer receives read-only snapshots in serialized order:

- `Recovered`: after actual disk reconciliation and checkpoint save, before
  new requests. Confirmed bytes include retained blocks; downloaded blocks is zero.
- `BlockCommitted(range)`: after write/sync, readback and checkpoint save. The
  half-open range is that block, including a possible short final block. Counts
  increase in completion order, which need not be offset order.
- `Paused`: the block budget was reached with incomplete coverage.
- `Complete`: coverage is complete and the full stored SHA-256 passed. A block
  event with confirmed bytes equal to total is insufficient to activate an artifact.

Observers are awaited while holding the output session lock; block observers also
hold the commit mutex. Keep them quick and do not wait for another operation on
the same session. Snapshots remain unchanged when later blocks finish. A callback
error propagates unchanged, cancels remaining jobs and releases locks. It is never
retried or treated as an HTTP failure. Saved blocks are retained for restart;
in-flight writes that were not saved are reconciled/refetched on the next run.
There is no final event on failure, and no cross-process exactly-once delivery or
power-loss guarantee. Reopening a complete session emits Recovered then Complete
with zero downloaded blocks. Empty artifacts follow the same two-event sequence.

CLI downloads accept `--progress` and print deterministic JSON lines before the
usual human-readable summary. Offline modes reject that flag. The exact schema is:

```text
["MFLPROGRESS1",phase,totalDecimal,confirmedDecimal,blocksDecimal,rangeOrNull]
["MFLPROGRESS1","block","7","3","1",["0","3"]]
```

Phase is `recovered`, `block`, `paused` or `complete`. Sizes, offsets and counts
are decimal strings. This is an observation format, not a checkpoint import or
an estimate of network traffic; HTTP retries do not increment committed blocks.

Run `moon run scripts/recovery_demo.mbtx` for real USGS data served over loopback.
It validates monotonic saved progress despite reverse block arrival, corruption
recovery, pause/resume and a complete reopen without fetching. Native tests inject
observer failure after the first saved block and verify that restarting requests
only remaining blocks, as well as empty objects and no completion for bad SHA-256.
Code/tests are project-authored under Apache-2.0; existing fixture/dependency
sources are unchanged and listed in `THIRD_PARTY_NOTICES.md`.
