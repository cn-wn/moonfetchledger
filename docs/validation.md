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
- Ubuntu/WSL, GCC 12.5: actual native core tests and actual native assembly example.
- 14 tests per target, including the checked README. Generated property cases cover
  129 binary sizes x 4 block sizes (516 complete reception/recovery round trips).
- Truncated checkpoints, malformed/unknown data, cancellation, foreign leases,
  rejected responses, failed readback, missing/corrupt blocks and final digests.
- Real data assembly: 28008 bytes, one invalidated block, final SHA-256
  `dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042`.

The default Windows machine has no MSVC SDK. Windows native execution is not
claimed as locally verified. The official async dependency requires MSVC on Windows;
MinGW is not a supported substitute. CI uses the Windows-2022 MSVC environment,
plus Linux and macOS. CI status must be checked after pushing; configuration alone
is not evidence of success.

An upstream async C stub produced GCC's ignored-return-value warning; project
MoonBit code is checked with `--deny-warn`. No dependency code was modified.

Reproduce in a shell with moon, node and the platform C compiler on PATH:

```text
moon run scripts/verify.mbtx
```

That script checks formatting/interface drift, strict checks, actual four-target
tests and the wasm/native real-data assembly example. Automation is MoonBit `.mbtx`.
