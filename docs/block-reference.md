# Audit files without a local checkpoint

A release publisher can distribute complete block records alongside an artifact.
Consumers who lost local progress metadata can locate damaged blocks without
network requests, content writes or creating sidecars. The reference is immutable
release metadata with an independently trusted exact-byte SHA-256 pin.

    let pin = @host.write_block_reference(spec, "publisher.bin", "release.blocks.mfl",
      chunk_size=65536)
    // Distribute pin through a separate trusted channel.
    let reference = @host.load_block_reference(spec, "release.blocks.mfl", pin)
    let report = @host.audit_with_reference(reference, "installed.bin")
    println(report.to_json().stringify())

Publication reads a regular source with exact expected length, indexes its blocks,
and requires the complete trusted digest before publishing anything. Source bytes
and sidecars are retained. Destinations and temporary files must be new; aliases of
the source or its session paths are refused. The returned pin covers published
UTF-8 bytes. It is not a signature: a pin distributed beside attacker-controlled
data establishes no authenticity unless that pin has independent authority.

Loading uses a regular file and bounded same-handle reads, capped at 16000000 bytes
plus a one-byte length probe. The portable BlockReference loader checks the pin
before UTF-8 decoding or schema parsing, requires the expected ObjectSpec, and
requires every block record. It reuses strict MFL1; there is no parallel schema
or migration. Unknown fields, malformed numbers/digests, duplicate/unsorted records
and partial progress checkpoints are refused. A loaded reference retains exact
authenticated text, including whitespace; publisher output is canonical.

Storage adapters can use StorageIndexer.block_reference after whole-source
verification, then BlockReference.session to obtain a fresh recovering session.
It starts with zero confirmed bytes. Records must be reconciled against actual
storage before recovery finishes; reference sessions do not share mutable progress.
These core APIs run on wasm, wasm-gc, JavaScript and native.

The native audit reports actual stored/confirmed bytes, sorted invalidated blocks,
coalesced missing ranges and completion using MFLAUDIT1. Complete coverage still
requires whole-file SHA-256; authenticated block records alone are insufficient.
Short or absent files are supported and extra bytes are refused without trimming.
An absent empty artifact is incomplete. Repeated audit reports are deterministic
for stable inputs. Existing local checkpoint contents are not consumed or trusted.

If an artifact or publisher source already has a regular .mfl.lock, a shared
cooperative lock excludes ledger writers. Metadata without its lock is refused.
For unmanaged files no lock is created: callers must ensure stable input and
exclude external writers. Same-size concurrent changes, malicious filesystem
substitution and power-loss durability remain outside this contract. Errors
preserve inputs; publication cleans only its own temporary through no-replacement
publication. Upstream clients that do not use the ledger lock must be serialized
with these operations by their application.

This milestone provides publication and read-only inspection. Existing managed
sessions already support WebDAV/local repair. Creating a new repair session for
damaged unmanaged content is a separate next capability.

Run the network-free real-data example:

    moon run --target native examples/reference

It publishes full records from the bundled 28008-byte USGS snapshot, damages one
byte in an unmanaged copy, reports only [8192,12288) as invalid and 23912 retained
bytes, repeats the audit, refuses a wrong pin, and verifies unchanged artifact/
metadata bytes and no sidecar creation. Licenses are recorded in
THIRD_PARTY_NOTICES.md and fixtures/README.md.
