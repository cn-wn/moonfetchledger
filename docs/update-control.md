# Update progress and cooperative cancellation

Native applications can pass an optional `host.UpdateControl` through release
loading, metadata loading, seed reconstruction, receiving, unsigned/signed
updates and verified export. Existing calls and download-only `DownloadProgress`
callbacks keep their behavior when no control is supplied. This adds no portable
core dependency on a filesystem or event loop.

`UpdateControl::new(on_progress?, pause_signal~=PauseSignal::new())` accepts a
serial async observer. Request cancellation with `control.request_pause()` or the
shared `PauseSignal`. One control belongs to one operation at a time; callbacks
must return promptly. Resume with a **fresh** control/signal. Catch
`host.UpdatePaused(phase, resumable)` separately from I/O/validation errors.
Observers can raise errors; these propagate without retrying the observer or
rolling back already installed checkpoints. A terminal observer error can occur
after delivery has been published; inspect the destination rather than assuming
that failure means nothing was written.

## Phases and counters

| JSON phase | Work observed |
| --- | --- |
| `release` | Bounded local/HTTP announcement loading, before signature acceptance |
| `authorizing` | Verified announcement, before monotonic acceptance |
| `metadata` | Hash-bound metadata loading; signed updates enter after acceptance |
| `scanning` | Aggregate bytes scanned across all input seeds, every 64 KiB |
| `reusing` | Reused target bytes saved in the checkpoint, per saved batch |
| `recovering` | Retained staging blocks read back; saved coverage at completion |
| `downloading` | Saved target coverage, including retained/reused bytes |
| `verifying` | Whole-file verification or export source reconciliation |
| `exporting` | Bytes copied to the private destination temporary |
| `export-readback` | Synced destination bytes independently read back |
| `finished` | Update verified, and requested export successfully published |

Phases can repeat (for example verification before and during export). Counters
reset at phase boundaries and are **not** one monotonically increasing global
percentage. `processed_bytes/total_bytes` describes that phase; metadata/release
requests may use `0/0` for an unknown total. `confirmed_bytes` counts validated
target coverage at the reported boundary, never HTTP body traffic. During initial
recovery it remains zero until the corrected checkpoint is saved. Export source
reconciliation reports only the blocks checked so far. Recovery and export source
reconciliation use a logical target cursor for processed bytes: known holes can
advance that cursor without content reads. These counters do not measure disk I/O.

`UpdateProgress::to_json()` returns exactly:

```json
["MFLUPDATEPROGRESS1","downloading","running","16384","28008","16384",true]
```

The seven fields are tag, phase, status (`running` or `paused`), processed bytes,
total bytes, confirmed bytes, and resumable boolean. Decimal strings preserve
Int64 values in JavaScript readers. No paths, URLs or credentials are included.
`finished/running` is the successful terminal event; a paused result never emits it.

## Pause and restart boundaries

- Scanning stops before staging creation. Retry with the original seed inputs.
- Reuse and receive flush pending short batches before reporting a pause.
  In-flight parallel requests drain; saved progress is emitted after checkpoint
  installation, including when checkpoint batching is enabled.
- Verification pauses retain staging. Resume repeats verification rather than
  serializing a partial hash state.
- Export cancellation removes only its owned `.next` file. The ready destination
  remains absent and the staging/checkpoint/lock session remains usable.
- `resumable=true` means an attached staging session is available: retain all its
  files and switch an initial update to explicit resume without seeds. False
  means repeat the original operation parameters. Standalone release/metadata
  loaders have no attached staging and report false even when the caller will
  later resume an existing session. A signed metadata pause does **not** reset an
  already accepted release version; retry the same authorized release/state.
- Cancellation is cooperative: filesystem calls, signature verification and a
  current bounded HTTP request are not forcibly interrupted. A metadata/release
  request checks before/after the request; the configured timeout is at most
  120000 ms. Generic range callbacks must enforce their own bounds. There is no
  fixed cancellation-latency or power-loss guarantee. A retrying range source can
  also consume its configured attempt budget before returning.
- A request from the final `finished` observer arrives after completion and does
  not turn success into a pause. Legacy block budgets still return an ordinary
  incomplete report; typed pause applies to the new control.

## Runnable example and CLI

```text
moon run --target native examples/update-control
moon run --deny-warn scripts/delta_update_demo.mbtx
moon run --deny-warn scripts/signed_update_demo.mbtx
```

The native example uses the real public-domain USGS fixture: reconstruct from a
local seed, cancel export readback, assert no ready/temporary file remains, then
resume with zero artifact GETs and byte-exact delivery. CLI drivers run actual
child processes, verify a preexisting marker prevents staging, preserve signed
state, remove their owned marker, and retry offline with a complete local seed.
The unsigned CLI driver also creates a marker during an active HTTP transfer,
checks the typed paused record at 8192 saved bytes, and resumes in a new process.
Host tests cover cancellation throughout the stages, short-tail flushing,
observer failures, exact JSON, input preservation and signed rollback protection.

Both `cmd/update` and `cmd/release` accept `--progress-json` and `--cancel-file
PATH` in update mode. A supervisor creates the marker to request pause; keep it
present until the child emits a `paused` record and exits. Remove it before
retry/resume. The child never removes the marker. A cooperative pause exits zero
and emits a paused JSON record even without `--progress-json`; consumers must
distinguish it from `finished`. Existing summary records remain unchanged.
The marker is polled at progress boundaries, including saved checkpoint batches;
a larger checkpoint batch can therefore delay recognition of a new CLI marker.

```text
moon run --target native cmd/update -- --metadata target.delta --metadata-sha256 TRUSTED_PIN --seed old.bin --output staging.bin --export-to ready.bin --checkpoint-blocks 64 --progress-json --cancel-file pause.marker
```

After a pause with resumable true, remove the marker and replace `--seed old.bin`
with `--resume`, keeping the same metadata, staging and new delivery path. Before
staging exists, repeat the initial command. See [checkpoint batching](checkpoint-batching.md)
for saved-write/repeated-work tradeoffs.
