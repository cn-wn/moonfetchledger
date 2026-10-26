# Observed baseline — 2026-10-26

baseline-20261026.json is the unedited MFLSTRESS-SUITE1 driver output for
10, 100 and 1024 MiB plus a 17-byte tail, seven cases each, 1024 KiB chunks,
zero injected delay and one sample per case. All coverage, body-count, digest
and source-preservation assertions passed.

The core scanner/receiver corresponds to parent revision e93ba40. Measurement
tooling is introduced alongside this record. Toolchain: Linux moon/moonrun
0.1.20261023, moonc v0.10.17+d971670cd, native release, WSL2 on the checkout's
Linux filesystem. Workers were pinned to logical CPUs 0 and 1. This is a local
development environment, not an isolated benchmark lab; development checks
could run on other cores. Wall times are illustrative single observations.
RSS is worker VmHWM and does not include filesystem/page cache or compilation.

Representative 1024 MiB + 17 observations:

| Case | Reused bytes | HTTP artifact requests | HTTP body bytes | Preview ms | Update ms | Peak RSS KiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| baseline | 0 | 1025 | 1073741841 | 1 | 55298 | 15968 |
| identical | 1073741841 | 0 | 0 | 43501 | 105214 | 11216 |
| shifted | 1073741841 | 0 | 0 | 44826 | 109050 | 12380 |
| sparse | 939524096 | 129 | 134217745 | 43661 | 107127 | 16012 |
| insert-delete | 919601169 | 147 | 154140672 | 39719 | 95459 | 16472 |
| reordered | 1073741841 | 0 | 0 | 45665 | 112554 | 12412 |
| low-reuse | 0 | 1025 | 1073741841 | 49581 | 99091 | 18512 |

These data establish selective content transfer and bounded observed worker
memory for these cases. They do not show a throughput advantage: reuse was
slower than full download on this fast local origin. Preview and rescanning
cost are material; optimize and remeasure before making performance claims.
No conclusion about production network billing, all file distributions,
other operating systems or asymptotic memory is inferred.

Reproduce and interpret fields using [the workload contract](../stress-matrix.md).
Generated large inputs are removed; only the small result artifact is committed.
