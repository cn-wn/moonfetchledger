# Validation record — 2026-10-09

Stable download channel binaries match the local version:

```text
moon 0.1.20260920 (914d7da 2026-09-20)
moonc v0.10.14+7d59c7ec9 (2026-09-18)
moonrun 0.1.20260920
```

The Windows moon executable matches the official latest checksum list at
https://cli.moonbitlang.com/binaries/latest/moonbit-windows-x86_64.sha256 .
The isolated Linux toolchain reports the same compiler/build-tool versions.

- Windows: strict core tests on wasm, wasm-gc and js.
- Ubuntu/WSL, GCC 12.5: actual native tests and actual native assembly example.
- 22 tests per portable target, including the checked README. Generated property cases cover
  129 binary sizes x 4 block sizes (516 complete reception/recovery round trips).
- Native host adds response-range validation, preservation of unrelated/extra
  data, exclusive-lock/reopen, checkpoint preservation and retry-budget/wait-hint
  boundary tests, read-only auditing, shared/exclusive lock interaction and
  whole-file integrity, local adoption, export, repair and progress (44 total on native).
- Coverage projection: all 128 confirmation masks for seven blocks, including
  reserved gaps, short final blocks, per-byte partition, exact coalescing, fresh
  return arrays, checkpoint preservation, restoration gate and maximum length.
- Offline actual HTTP/disk workflow passed on Linux: reverse arrival order,
  separate paused/resumed processes, 8192 retained bytes, one invalidated block,
  exactly five repair requests, full-byte equality, no requests on complete reopen,
  rejected changed ETag and successful subsequent retry.
- Bounded retry scenarios: 503 then 429 then valid 206, exactly nine requests for
  seven committed blocks; three-attempt exhaustion with zero written bytes and
  empty coverage followed by successful restart; timed-out request then successful
  retry; changed ETag still refused after one request with retries enabled.
- Offline audit before repair returns exactly 8192 confirmed bytes and two gaps;
  repeated reports are identical, round-trip JSON losslessly, issue no requests
  and preserve output/checkpoint/lock bytes. Complete audit verifies SHA-256 and
  emits an empty gap list. Native tests cover truncated/absent files, absent empty
  output, bad final hash, wrong identity, malformed schema and extra-data refusal.
- Storage indexing: 516 binary size/block-size combinations produce byte-identical
  reception checkpoints, survive restoration and pass full-digest verification.
  Short reads are correctable; incomplete/wrong/empty-wrong digests expose no session.
- Native local adoption: original-file preservation, empty file, competing locks,
  bad digest and lengths, existing checkpoint/temporary refusal and later recovery.
  The real-data local demo adopts the 28008-byte snapshot, reuses it without
  fetching and detects a later damaged block while preserving the checkpoint.
- Export: full-byte equality and preservation of source/sidecars, empty artifact,
  incomplete/corrupt/extra/truncated source refusal, wrong final digest and schema,
  source lock exclusion, reserved path aliases and existing temporary preservation.
  Publication tests inject a writer failure and a destination created during copy;
  failures retain the other owner's file and remove only owned temporary data.
  End-to-end export verifies real data, conflicting-mode rejection, corruption
  refusal and successful retry after the fixture's original bytes are restored.
- Local repair: 260 size/layout combinations yield identical indexed checkpoints;
  incomplete/untrusted source, changed reads, wrong layout/identity, foreign leases,
  truncation/absent target, empty data, extra data and temporary ownership refusal.
  The USGS workflow repairs one block offline, retains 23912 bytes, then repeats
  with zero copies and exports the repaired artifact.
- Progress: saved coverage is readable inside callbacks; first-block callback
  failure releases the lock and restart fetches only the remaining two blocks.
  Tests cover initial failure, zero-budget pause, empty completion and no Complete
  event on bad whole digest. The real-data CLI verifies monotonic counts/JSON
  round trips during reverse arrivals, five-block repair and zero-fetch reopen.
- Truncated checkpoints, malformed/unknown data, cancellation, foreign leases,
  rejected responses, failed readback, missing/corrupt blocks and final digests.
- Real data assembly: 28008 bytes, one invalidated block, final SHA-256
  `dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042`.

The default Windows machine has no MSVC SDK. Windows native execution is not
claimed as locally verified. The official async dependency requires MSVC on Windows;
MinGW is not a supported substitute. CI uses the Windows-2022 MSVC environment,
plus Linux and macOS. CI status must be checked after pushing; configuration alone
is not evidence of success.

Upstream async C stubs produced GCC's ignored-return-value warning and MSVC's
EINVAL macro-redefinition warning; project
MoonBit code is checked with `--deny-warn`. No dependency code was modified.

Reproduce in a shell with moon, node and the platform C compiler on PATH:

```text
moon update
moon run scripts/verify.mbtx
```

That script checks formatting/interface drift, strict checks, actual four-target
tests, the wasm/native real-data assembly example and the offline HTTP/disk workflow
described in `recovery-demo.md`. Automation is MoonBit `.mbtx`, with dependency
versions pinned independently in the script import headers.
`local_storage_demo.mbtx` verifies adoption and export without a network origin.
The fixture server shuts down through a finite accept loop and an explicit stop
request, including on Windows. Verification commands have three-minute budgets;
CI jobs have a ten-minute ceiling and print each stage before starting it.
