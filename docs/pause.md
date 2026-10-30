# Controlled pause and resume

For a typed pause throughout a complete unsigned/signed update, including scans
and export, see [UpdateControl](update-control.md). The legacy download-only
signal described here continues to return an ordinary `DownloadReport`.

An updater's UI or supervising task can request a pause without throwing from its
progress callback or interrupting a storage write:

```moonbit
let signal = @ledger.PauseSignal::new()
let report = @host.download(spec, path, pause_signal=signal, on_progress=event => {
  if event.phase is @host.BlockCommitted(_) { signal.request_pause() }
})
```

Keep the signal in application state and call `request_pause()` from the pause
action. The snippet requests it on the first saved block to illustrate the same
transition. Access must be serialized on the application's async scheduler;
PauseSignal is portable but is not a synchronization primitive for OS threads.

The native downloader checks intent before scheduling each batch. A queued batch
drains through normal response validation, write/sync/readback and checkpoint save.
No further batch is scheduled. At most `parallel` blocks belong to that batch;
progress continues for its completed blocks, followed by Paused for incomplete
coverage. A pre-requested signal or a request in Recovered prevents all new fetches.

The signal is one-shot and requests are idempotent. Resume using a fresh signal
or omit it. Preserve the output, checkpoint and lock sidecar. New invocations
reconcile disk and fetch only remaining blocks. Completion takes precedence: if
the drained batch completed the artifact, whole-file verification runs and the
result/event is Complete, including empty or already complete objects.

A pause does not mask HTTP/version, digest, storage or observer errors. Such errors
still propagate and produce no final Paused/Complete event. This API does not abort
an active request, retry wait or disk operation, does not promise a wall-clock
pause deadline, and does not install OS signal handlers. Existing block budgets,
progress observers and calls without a signal preserve their behavior.

Run `moon run --target native examples/controlled`. It serves the bundled USGS
snapshot on loopback, requests pause after the first saved block, drains the
three-block batch, audits the remaining gap, resumes four blocks with 12288 bytes
retained, verifies exact data/SHA-256 and reopens without fetching. No private
service is needed. Native tests cover pre-requested/reused signals, short final
blocks, fresh resume, empty completion and a fatal response after pause was
requested. Code/tests reuse project-authored loopback patterns; data and dependency
sources remain in `THIRD_PARTY_NOTICES.md` under their recorded licenses.
