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
