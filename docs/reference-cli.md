# Block reference command-line workflows

The native CLI provides the same publisher and checkpoint-free audit workflow as
the library. No application code or running origin is required. Obtain the release
identity and block-reference SHA-256 through independent trusted input.

## Publish complete block records

    moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 IDENTITY_PIN --output publisher.bin --write-block-reference release.blocks.mfl --chunk-size 65536

Here --output names the read-only publisher source. Its exact length and complete
SHA-256 must match the identity. The reference destination and its .next temporary
must be new. Successful publication prints one line:

    block-reference: sha256=REFERENCE_PIN

Distribute REFERENCE_PIN independently from untrusted reference storage. The
identity manifest's pin and the block reference's pin authenticate different bytes;
neither is interchangeable with the artifact's whole-file SHA-256. Inline --url,
--length, --etag and --sha256 can replace the identity-manifest pair. Publication
accepts only identity options, --output, --write-block-reference and --chunk-size.

## Audit unmanaged or retained content

    moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 IDENTITY_PIN --output installed.bin --audit --block-reference release.blocks.mfl --block-reference-sha256 REFERENCE_PIN

The block-reference pair is mandatory together. Its independently pinned complete
records must match the expected identity. No chunk-size override, network policy,
credentials, progress, publication or other artifact mode is accepted. Artifact,
checkpoint, lock and metadata bytes are preserved; unmanaged/absent artifacts do
not acquire new sidecars. Existing managed locks are respected by the library.

The result is deterministic MFLAUDIT1 JSON. A valid audit exits successfully even
when complete=false; examine the report's gaps and invalidated ranges. Complete
requires whole-file verification. Bad pins, malformed/partial metadata, extra
artifact data, conflicting options and input descriptors aliasing artifact/session/
export/reference destination paths fail. Existing aliases resolvable with realpath
are checked before artifact access; trusted-directory assumptions still apply.

## Recover lost progress and repair

    moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 IDENTITY_PIN --output installed.bin --adopt-with-reference --block-reference release.blocks.mfl --block-reference-sha256 REFERENCE_PIN
    moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 IDENTITY_PIN --output installed.bin --repair-from publisher.bin --stop-after-blocks 1 --progress
    moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 IDENTITY_PIN --output installed.bin --repair-from publisher.bin
    moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 IDENTITY_PIN --output installed.bin --export-to ready.bin

Adoption is explicit and exclusive with audit, publication, ordinary --adopt,
repair, export, credentials and download policies. It reads an existing regular
artifact, confirms only blocks matching the independently pinned reference, and
creates a NEW .mfl checkpoint under an exclusive cooperating lock. Damaged or
truncated content is accepted; extra bytes are refused without truncation. Artifact
and release metadata bytes are never changed. Existing .mfl, .mfl.next and
.mfl.recovering files are refused and preserved. A created lock may remain after a
failed adoption; it conveys no verification authority.

The emitted MFLAUDIT1 report describes the reconstructed coverage, not completion
of repair. Continue with the ordinary repair/download API; no re-publication or
reference input is needed. Local repair fully verifies the backup first, saves
each copied block and can pause/restart in another process. Completion and export
still require whole-file verification. Network repair uses the existing native
download command or WebDAV Source.receive; this offline example needs no origin.

Run the actual-file workflow on the bundled USGS data:

    moon run scripts/reference_demo.mbtx

It uses an unreachable origin URL, publishes canonical records, audits one damaged
block retaining 23912 bytes under both identity input forms, refuses bad pins and
mode/path conflicts without sidecar creation, preserves unrelated temporaries,
rejects a damaged publisher source, and produces identical reference bytes on
subsequent valid publication. The verification script runs it on all CI systems.

    moon run scripts/reference_recovery_demo.mbtx

This second actual-command workflow reconstructs 23912 valid bytes, repairs one
4096-byte block and exports the verified artifact. It then removes only its own
checkpoint, damages two separated blocks, reconstructs 19816 bytes, pauses after
one saved repair and finishes in a fresh process. It compares complete checkpoints
with the original reference byte-for-byte, preserves existing metadata on refusal,
and retries successfully after correcting extra-data input. Both scripts run in CI.
