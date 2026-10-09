# Delivering a verified artifact to a new path

`host.export_verified(expected, output, destination)` copies a completed retained
artifact to a fresh consumer path. Use it after download or local adoption, for
example to deliver a dataset into a processing queue or a versioned model file
into an application's ready directory while retaining the repairable cache.

```text
moon run --target native cmd/fetch -- --export-to NEW_PATH --url URL --output RETAINED_PATH --length N --etag QUOTED_ETAG --sha256 HEX
moon run scripts/local_storage_demo.mbtx
```

The CLI rejects combining export with audit/adoption or download-only options.
The independently trusted ObjectSpec is required. No network request is made.
The source must be a regular file with an existing `.mfl` checkpoint and `.mfl.lock`
sidecar. Its length must match exactly; unknown schema or changed identity fails.
The destination's parent must exist. Source/sidecar destinations are forbidden;
parent paths are resolved to reject aliases such as `./`. Case-equivalent source
session paths are conservatively refused even on a case-sensitive filesystem.

The source's shared cooperative lock is held throughout the workflow, rather than
released between audit and copy. Every recorded block is reconciled with actual
storage. A damaged block reports its range and directs the caller to audit/repair;
unrecorded gaps raise LedgerError.Incomplete. No checkpoint is rewritten.

A new destination-adjacent `.next` file is created exclusively. Copying uses at
most one ledger block at a time, verifies the digest of copied bytes, syncs the
file, then streams its actual readback through a second whole-file verifier.
Only a matching digest and exact lengths permit a synced no-replace rename to the
destination. The destination therefore becomes visible under its final name only
after these checks pass. Existing destinations and temporary files are preserved,
including a destination that appears after the initial existence check. Failed
verification cleans up the temporary file created by this invocation.

Successful export returns Unit and the CLI prints `exported: bytes=N`. The source,
checkpoint and lock remain available for later audit or repair; the exported file
has independent contents and receives no ledger sidecars. Export is a copy, not
in-place activation or replacement of a running application's file. Choose a new
versioned destination and let the consumer decide when to use it.

These semantics depend on the supported platform's no-replace filesystem rename
and honest file I/O. A trusted directory without external writers is required;
cooperative locks do not protect against malicious mutation or path replacement.
Access timestamps can change. There is no directory-fsync or power-loss guarantee.
Interrupted processes can leave a `.next` file; inspect and retain it explicitly
instead of silently overwriting it on restart. Linux, macOS and Windows native CI
exercise the implementation; the portable ledger's API and checkpoint format do
not change for export.

The real-data demo verifies exact USGS fixture bytes, source/checkpoint preservation,
existing-destination refusal, no publication for a damaged source, and successful
export after restoring the fixture's original bytes. Native tests additionally
cover incomplete coverage, final-digest mismatch, malformed schema, source locks,
empty files, path aliases and a competing destination created during publication.
Source data and existing dependencies are documented in `THIRD_PARTY_NOTICES.md`.
