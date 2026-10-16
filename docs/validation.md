# Validation record — 2026-10-17

Stable download channel binaries match the local version:

```text
moon 0.1.20261012 (748b63c 2026-10-12)
moonc v0.10.15+943464bfa (2026-10-12)
moonrun 0.1.20261012
```

The Windows and Linux moon executables match the official latest checksum lists:
https://cli.moonbitlang.com/binaries/latest/moonbit-windows-x86_64.sha256 and
https://cli.moonbitlang.com/binaries/latest/moonbit-linux-x86_64.sha256 .
The isolated Linux toolchain reports the same compiler/build-tool versions.
Windows moon SHA-256: `296a895d934b6a07522214cbf89caf0cf5605efe4fb82efe07b929fbf9d27432`;
Linux moon: `a31026b83410607909ebae469fa19e46c32201cfe403be6099e1da961a5ebf0f`.

- Ubuntu/WSL, GCC 12.5: actual four-target tests, native assembly and integration
  examples. Windows local tooling is used for strict checks and API discovery.
- 27 tests per portable target, including the checked README. Generated property cases cover
  129 binary sizes x 4 block sizes (516 complete reception/recovery round trips).
- Native host adds response-range validation, preservation of unrelated/extra
  data, exclusive-lock/reopen, checkpoint preservation and retry-budget/wait-hint
  boundary tests, read-only auditing, shared/exclusive lock interaction and
  whole-file integrity, adoption, export, repair, progress, pause, authentication,
  pinned manifests, interrupted checkpoint recovery and source/WebDAV integration
  (79 total on native, including the checked WebDAV usage example).
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
- Controlled pause: independent/idempotent signals, pre-requested and Recovered
  requests, batch draining, resume retaining six bytes and requesting only two
  remaining blocks, empty completion and fatal version errors after a pause.
  The real-data controlled example drains three blocks, retains 12288 bytes and
  fetches four remaining blocks before full verification and zero-fetch reopen.
- Bearer credentials: grammar/length boundaries, explicit loopback policy,
  malformed/unsupported URLs and exact resource binding before any file creation.
  Native tests verify rotation/resume retaining three bytes, one-request 401
  even with retries enabled and a 302 rejected without forwarding.
  The real-data CLI demo verifies environment input, two-block pause, expired
  credentials, five-block resume retaining 8192 bytes, token-free checkpoints and
  output, offline reuse, 403/302 refusal, reflected malformed-header redaction and
  authenticated 503 retry. TLS defaults are inspected in the pinned dependency;
  the reproducible authentication workflow runs over explicit test-only loopback.
- Truncated checkpoints, malformed/unknown data, cancellation, foreign leases,
  rejected responses, failed readback, missing/corrupt blocks and final digests.
- Real data assembly: 28008 bytes, one invalidated block, final SHA-256
  `dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042`.

- Release manifests: 36 identity round trips spanning Int64 maximum, values above
  2^53, Unicode, escaped controls and maximum resource length; deterministic bytes,
  whitespace parsing, all five field types, unknown/extra fields, noncanonical or
  overflowing lengths, invalid identities and unchanged MFL1 recovery behavior.
  Native tests verify exact-byte pins before parsing, source preservation, new-path
  publication conflicts, 65536/65537-byte boundaries, strict UTF-8, schema failures
  and successful reuse after refusal. The real-data demo publishes a pinned
  manifest, uses it for authenticated two-block pause/five-block resume and, with
  the origin stopped, audit/reuse/adopt/local repair/export. Identity option
  conflicts, manifest aliases in output/sidecar/export paths and tampered manifests
  fail before network/session mutation.

The default Windows machine has no MSVC SDK. Windows native execution is not
claimed as locally verified. The official async dependency requires MSVC on Windows;
MinGW is not a supported substitute. CI uses the Windows-2022 MSVC environment,
plus Linux and macOS. CI status must be checked after pushing; configuration alone
is not evidence of success.

Checkpoint-save recovery tests cover all 64 installed/candidate coverage-mask pairs,
monotonic actual coverage, sorted/deduplicated failed records, absent storage and
first-save recovery, malformed/schema/identity/layout/whole-digest refusal, extra
bytes, exclusive locks, 16M-byte bounds, unrelated temporary preservation and failed
installation cleanup. The real-data demo reconstructs an interrupted four-block
save, promotes 16384 confirmed bytes without network or artifact writes, resumes
only three remaining blocks, refuses stale coverage and reopens with the origin
stopped. Pinned-manifest recovery is verified in the manifest workflow.

WebDAV integration uses the published q2316367743/webdav 0.1.0, moonhttp 0.5.0,
Milky2018/xml 0.5.0 and a shared async 0.22.4 (recorded by `moon tree`). The previous
native HTTP entry point keeps its generated signature and delegates storage to
receive_from. The stable formatter normalizes Int32/default-label syntax; core
public interfaces and MFL1 bytes retain their existing contracts. In async 0.22.4
cancellation is no longer caught as an error, so the deprecated cancellation-error
predicate was removed from authenticated error redaction.

New tests check external metadata before artifact writes, error/retry recovery,
cross-call pause/repair/reopen, exact upstream conditional/range/auth headers, all
eight three-block sparse coverage masks, Int32/URL/auth/timeout limits, short/extra
bodies, status/ETag/range/encoding/length refusal, static credential-safe errors
and a checked public usage example. The WebDAV real-data example uses actual
published clients and sockets: upstream upload/full download, trusted adoption,
offline same-size corruption audit retaining 23912 of 28008 bytes, encoded-response
refusal without content writes, one-block repair, nonadjacent two-block pause/
reopen, verified export and stopped-origin zero-fetch reuse. Its fixture implements
only PUT/GET/OPTIONS, not a full WebDAV server or vendor interoperability suite.
No complete foreign corrupt file is adopted as trusted coverage. Modelhub remains
a comparison reference; there is no dedicated modelhub integration.

Unified checkpoint input tests cover four ordinary native reader workflows,
five malformed UTF-8 encodings, directory preservation, exactly 16000000 accepted
bytes and 16000001 refused bytes, no fetch/publication on rejection, lock release
and successful reuse after replacing malformed metadata. All five native session
entry points now use bounded reads on the same handle as the size/kind checks;
the EOF probe reads at most one additional byte. The real-data local storage demo
also checks CLI refusal/preservation across receive, audit, local repair and export.

The complete verification script passed in a Linux-local snapshot,
with all 101 project files compared byte-for-byte against the original working
tree before and after validation. In the Windows-mounted checkout the manifest
workflow reached the existing 180-second subprocess budget; the Linux-local run
kept that budget and completed all stages. Use a Linux-local checkout when a
cross-OS mounted filesystem makes repeated CLI invocations too slow. This is an
environment observation, not a performance claim about the library.

Local repair control tests exercise 32 sparse-coverage/budget combinations,
saved coverage inside callbacks, exact remaining-copy counts on resume,
pre-requested/Recovered/BlockCopied pause signals, idempotent paused reopen,
completion precedence, empty artifacts, initial/block callback failure and lock
release. Negative budgets fail before files are opened. Invalid backup hashes
remain fatal under zero budgets and pause intent; a backup modified by a callback
is refused before copying. Target damage during a callback cannot emit Complete.
The CLI's real-data demo pauses after one of two nonadjacent repairs, audits the
remaining gap, validates JSON round trips, resumes with 23912 retained bytes,
rejects unsupported controls without mutation, and completes a zero-budget reopen.
Existing no-control repair behavior and MFL1 checkpoint bytes remain unchanged.
Windows CI initially passed all 79 native tests, then exposed CRLF delimiters in
the new CLI example's line comparison. The example now strips only the delimiter's
single trailing CR before checking canonical JSON; both LF and CRLF are tested
against explicit expected records. Run `moon run scripts/local_storage_demo.mbtx
--check-progress-lines` to check this parser without a native C compiler, or omit
the option to run the full actual-file workflow.

Upstream async C stubs produced GCC's ignored-return-value warning and MSVC's
EINVAL macro-redefinition warning; project
MoonBit code is checked with `--deny-warn`. No dependency code was modified.
The current standalone-script dependency graph also reports a duplicate import
warning for async/internal/c_buffer. This tool/dependency warning is recorded
separately from the project's strict source checks and is not suppressed by patches.

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
`manifest_demo.mbtx` verifies pinned publisher-to-consumer identity and all offline modes.
`checkpoint_recovery_demo.mbtx` verifies interrupted checkpoint promotion and resume.
`moon run --target native examples/webdav` verifies the existing-client extension.
The fixture server shuts down through a finite accept loop and an explicit stop
request, including on Windows. Verification commands have three-minute budgets;
CI jobs have a ten-minute ceiling and print each stage before starting it.
