# Pinned release identity workflow

Artifact publishers and updater authors can distribute one object identity instead
of repeatedly assembling four CLI arguments. Consumers verify an independently
trusted manifest SHA-256 before any artifact network request or session mutation.
The same identity drives downloads, resume, audit, adoption, local repair and export.

## Publisher and consumer APIs

```moonbit
let text = spec.to_manifest()
let parsed = @ledger.ObjectSpec::from_manifest(text)
// Native, asynchronous integration:
let pin = @host.write_manifest(spec, "release.json")
let identity = @host.load_manifest("release.json", independently_trusted_pin)
let result = @host.download(identity, "retained.bin", auth~)
```

`ObjectSpec.to_manifest` has deterministic output. `ObjectSpec.from_manifest`
preserves all identity values and rejects unsupported data with `InvalidManifest`.
Parsing does not authenticate the publisher. `write_manifest` writes UTF-8 without
a BOM or final newline, syncs and publishes to a new path without replacement;
its returned pin hashes those exact bytes. Existing files and unrelated `.next`
temporaries are preserved. `load_manifest` accepts only a regular file of at most
65536 bytes, reads with a size bound, verifies the supplied lowercase SHA-256, then
strictly decodes UTF-8 and parses the schema. I/O errors propagate. It writes no
manifest, artifact, lock or checkpoint. Input growth is rejected rather than trimmed.

## CLI workflow

Generate a release identity from trusted publisher metadata:

```text
moon run --target native cmd/fetch -- --url URL --length N --etag QUOTED_ETAG --sha256 ARTIFACT_SHA256 --write-manifest release.json
```

The command prints `manifest: sha256=HEX`. Obtain URL, length, strong ETag and
artifact SHA-256 from your verified release process. Publish the manifest and
communicate its pin through an independent trusted release channel. The pin is
not a signature: a hash fetched alongside a manifest from the same untrusted
source cannot establish authenticity. This adapter does not discover or sign releases.

Use the independently obtained pin with your local manifest:

```text
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output retained.bin --stop-after-blocks 2
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output retained.bin
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output retained.bin --audit
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output retained.bin --export-to ready.bin
```

`--manifest` and `--manifest-sha256` are required together. Inline `--url`,
`--length`, `--etag`, `--sha256` cannot be mixed with a manifest, even if their
values match. There are no overrides. Existing inline CLI invocations still work.
Existing artifact/session/export paths that resolve to the input manifest are
rejected, including directory/symlink aliases; comparisons conservatively ignore
path case. This is accidental-path protection, not protection against hardlinks
or a malicious filesystem writer racing the checks.
`--write-manifest` accepts only inline identity and a destination; output paths,
credentials, offline modes and download options are rejected in publisher mode.
Authenticated downloads keep using `--bearer-env NAME` and the HTTPS boundary in
`auth.md`. Credentials are not part of the manifest. Identity metadata must not
contain secrets because it is intentionally persisted in manifests/checkpoints.

## Exact schema and boundary

MFLARTIFACT1 is an exact five-element JSON array:

```text
["MFLARTIFACT1",resource,lengthDecimal,strongEtag,artifactSha256]
```

Length is a canonical decimal string in 0..9223372036854775807, avoiding loss above
JavaScript's exact-number range. Resource, strong ETag and artifact digest use the
existing ObjectSpec limits. Core parsing accepts at most 65536 code units. Native
loading additionally enforces 65536 bytes, strict UTF-8 and exact-byte hashing;
whitespace/escape changes require a new pin even when parsed identity is equal.
No URL normalization, redirects, alternate download locations, arbitrary release
JSON, signed-manifest formats, collections, credentials or unknown fields are
supported. All extra/unknown data is rejected. MFL1 checkpoint bytes and object
identity comparison are unchanged; a different artifact identity still requires
an explicit new session. Download block limits apply separately from manifest parsing.

## Reproducible end-to-end demonstration

Run `moon run scripts/manifest_demo.mbtx`. It publishes a manifest for the real
28008-byte USGS fixture, pins the exact bytes, refuses missing/conflicting identity
inputs and tampering before session creation or mutation, pauses an authenticated
download after two blocks, then resumes five blocks retaining 8192 bytes. Exactly
seven distinct blocks are requested. After closing the loopback origin, it audits,
reopens with zero fetches, adopts a backup, repairs one damaged block and exports
the verified file. No private infrastructure or real credentials are needed. The
strong ETag is assigned by the local fixture server, not asserted as USGS metadata.
Unit tests cover Int64 boundaries, deterministic round trips, malformed schemas,
UTF-8 refusal, size limits, publication conflicts and recovery after failure.
Sources/licenses are recorded in `THIRD_PARTY_NOTICES.md` and `fixtures/README.md`.
