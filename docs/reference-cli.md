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

These commands publish and inspect. Creating a new recovery checkpoint for damaged
content remains available through the library; CLI adoption is a separate next
capability. Existing managed sessions use the ordinary repair/download commands.

Run the actual-file workflow on the bundled USGS data:

    moon run scripts/reference_demo.mbtx

It uses an unreachable origin URL, publishes canonical records, audits one damaged
block retaining 23912 bytes under both identity input forms, refuses bad pins and
mode/path conflicts without sidecar creation, preserves unrelated temporaries,
rejects a damaged publisher source, and produces identical reference bytes on
subsequent valid publication. The verification script runs it on all CI systems.
