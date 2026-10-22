# Read-only update planning

Use `host.preview_seed(reference, old_file)` before deciding whether to update a
large artifact. It returns a portable `SeedPlan` with verified reusable matches,
`download_bytes()`, coalesced `missing_ranges()` and deterministic `to_json()`.
The target index is authenticated first by the existing pinned delta loader.

```text
moon run --target native cmd/update -- --preview --metadata v2.delta --metadata-sha256 TRUSTED_PIN --seed v1.bin
moon run --target native examples/delta
moon run scripts/delta_update_demo.mbtx
```

The CLI permits local or remote metadata (the latter fetches metadata only), but
preview forbids output/export, resume, chunk overrides and download controls.
Local preview itself makes no network requests, state writes or sidecars. Existing
seed locks are respected. A changed seed length fails; exclude unrelated writers.
Reconstruction later rescans and verifies each selected block before copying;
a preview does not authorize writing or guarantee a future file snapshot.

MFLPLAN1 is exactly `[tag, targetLength, scannedBytes, reusedBytes, downloadBytes,
matches, gaps]`. All numbers are decimal strings. Each match is
`[sourceStart, sourceEnd, targetStart, targetEnd]`; each gap is `[start,end]`.
Ranges are half-open, target sorted and freshly allocated on access. Logical
download bytes exclude retries, HTTP/TLS overhead and metadata bytes; they are
an estimate of missing content, not a network billing limit.

The USGS-derived example needs 12288 of 23943 target bytes and reuses 11655.
The actual-process CLI demo checks the preview before staging and then compares
it with the completed workflow. No private service or token is needed.

## Several old versions

`host.preview_seeds(reference, ordered_paths)` computes a union from 1..32 regular
files. `host.reuse_from_seeds` reconstructs a new session from that union;
`host.update_from_seeds` additionally receives gaps and exports verified content.
Resume through the existing single update API with `resuming=true` and no seed.
The old single-seed API delegates to the same reconstruction engine.

Portable callers can use `SeedPool::new(reference)`, `add(SeedPlan)` and `finish()`.
Plans must match the exact target identity AND chunk layout. The first input
providing a block wins, then its first matching byte offset. Unused/redundant
seeds contribute zero bytes. Finish is idempotent and later additions fail.
Return arrays are fresh snapshots. Scanning retains one temporary seed plan and
O(target block count) selected matches, plus up to 32 file handles and locks.

`SeedPoolPlan` provides target-sorted `matches()` with zero-based `seed_index`,
`per_seed_reused_bytes()`, `download_bytes()`, `missing_ranges()` and MFLPOOL1 JSON:
`[tag, targetLength, scannedBytes, reusedBytes, downloadBytes, perSeedBytes,
matches, gaps]`; a match is `[seedIndex, sourceStart, sourceEnd, targetStart,
targetEnd]`. Numbers are decimal strings. These plans are advisory and not a
persisted authorization format. Reconstruction rescans/rechecks selected bytes.

All seed handles and cooperative shared locks remain held during staging.
Invalid/missing/duplicate canonical paths and all seed/session-to-output aliases
are refused; no seed is silently skipped. Owned partial staging is retained on
I/O failure for normal receiver recovery. Same-size external changes still
require the caller's stable-input contract; no malicious-filesystem guarantee.

```text
moon run --target native cmd/update -- --preview --metadata v2.delta --metadata-sha256 TRUSTED_PIN --seed v0.bin --seed v1.bin
moon run --target native cmd/update -- --metadata v2.delta --metadata-sha256 TRUSTED_PIN --seed v0.bin --seed v1.bin --output staging --export-to ready
moon run scripts/seed_pool_demo.mbtx
```

The self-contained CLI demo combines two incomplete USGS-derived files into the
exact 28008-byte target without artifact requests, preserves both sources and
checks read-only planning and control-error preservation. This is a regular-file
client extension, not zsync-format compatibility or a shared chunk cache.
