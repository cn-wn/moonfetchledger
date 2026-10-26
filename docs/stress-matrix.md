# Measured file-update workloads

```text
moon run --deny-warn scripts/stress_matrix.mbtx
moon run --deny-warn scripts/stress_matrix.mbtx --sizes 10,100,1024 --chunk-kib 1024
moon run --deny-warn scripts/stress_matrix.mbtx --sizes 10 --chunk-kib 64 --delay-ms 10 --repeat 3
```

The driver builds `cmd/workload` in native release mode once and executes a fresh
child process for every sample. The default is seven 10 MiB cases. Size controls
are 1..1024 MiB, plus a deliberate 17-byte final block; choose chunks 1..4096 KiB.
Data lives in a newly owned directory under `_build/stress` on the checkout's
filesystem. Each case removes its data; JSON reports remain. Plan for roughly
four times the target size of temporary storage. Full-scale runs are opt-in,
not part of normal CI. Native C tooling is required; nothing is published.

Input is project-generated xorshift32 binary data, explicitly SYNTHETIC. It is
not the real USGS fixture used by the normal integration examples, nor a crypto
RNG. Fixed generation and a byte-sequence/segmentation test make runs repeatable.
The foreign seed complements target bytes; every scenario's expected coverage
is checked against actual strong matching, never assumed to be successful.

| Case | Seed and required invariant |
| --- | --- |
| baseline | Empty seed: all target content received over loopback HTTP. |
| identical | Exact target: all content reused, no artifact GET. |
| shifted | Seven-byte prefix: matches move, all content reused. |
| sparse | First byte of every eighth block changed: only those blocks fetched. |
| insert-delete | Every seventh block removed, extra bytes inserted: retain every remaining block. |
| reordered | Complete blocks reversed, final short block retained: all content reused. |
| low-reuse | Complemented foreign data: all target content fetched. |

Each case publishes a whole-digest-gated target index, previews bounded reuse,
updates through actual HTTP, verifies exported content and hashes both source
files again to prove preservation. Scans admit exact seed length and at most
eight target lengths of candidate SHA input; exhaustion fails explicitly.
The loopback origin validates requested ranges/validators and counts successful
response bodies. It must agree with missing content and completed block counts.

MFLSTRESS1 rows are arrays in this order:

```text
[tag, case, targetBytes, chunkBytes, delayMs, seedBytes, reusedBytes,
 missingBytes, candidateHashInputBytes, artifactRequests, artifactPayloadBytes,
 setupMs, previewMs, updateMs, totalMs, peakRssKiBOrNull]
```

Numeric values are decimal strings; RSS is null when Linux `/proc/self/status`
VmHWM is unavailable. RSS belongs to the worker including fixture/origin and all
phases, not the compiler, and excludes filesystem cache. Setup includes fixture
creation/publication; update includes rescanning, staging, reception, full digest
verification and export; total additionally includes preservation checks and
server shutdown, but excludes cleanup. Timings use system wall-clock milliseconds;
a backwards clock fails. No elapsed-time/throughput assertion is imposed.

`artifactPayloadBytes` counts HTTP artifact body content, not headers, metadata,
TCP/TLS overhead or metered-link billing. Local HTTP has no TLS. Optional delay
is an explicit synthetic delay per origin request, not measured network latency.
Compare baseline and reuse within the same size/chunk/delay/build environment;
repeat samples before drawing conclusions. Local reuse may save bandwidth while
taking longer on fast loopback. No performance superiority is claimed.

Per-sample files and a MFLSTRESS-SUITE1 aggregate are created under `_build/stress`.
They record observed values, not canned results. A failed sample stops the run
and retains earlier result rows. CI exercises a 1 MiB/64 KiB smoke matrix on each
native OS; manual 10/100/1024 MiB runs provide separate scale evidence.
