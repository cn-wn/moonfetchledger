# Signed release authority

`release` is a portable application policy layer for file updates. It reuses
`hustcer/ed25519@0.6.1` (Apache-2.0), rather than implementing cryptography.
It authenticates the publisher's choice of exact MFLDELTA1 bytes; the existing
delta parser then authenticates target identity and block checksums with that pin.

1. Construct `Release::new(product, channel, version, issued_at, expires_at,
   metadata_url, metadata_sha256)`. Times are Unix seconds; validity is at most
   31536000 seconds. Versions are positive Int64 counters, not semantic versions.
2. The publisher calls `release.sign(private_seed)` with a privately held 32-byte
   seed. Output is deterministic. The seed is never part of the descriptor.
3. Independently provision a 32-byte public key and expected product/channel.
   `ReleaseTrust::new(key, product, channel, minimum_version=...)` validates the
   key and caches the upstream verifier.
4. `trust.verify(bytes, trusted_unix_seconds)` returns an unforgeable
   `ApprovedRelease` only after signature, scope, version and time checks.
   Issue time is inclusive; expiry is exclusive. Verify again when starting a
   later operation. Use its `release.metadata_sha256` with the existing host
   local/remote delta loader, then the seed/update APIs.

Run `moon run --target wasm examples/release` (also native/wasm-gc/JS).
The example's public deterministic seed is TEST DATA, never a deployment key.
It demonstrates authorization only; `examples/delta` demonstrates file rebuilding.

## Exact format and rejection rules

The envelope is canonical compact UTF-8 JSON, at most 16384 bytes:

```text
["MFLRELEASE1", payloadText, lowercaseSignatureHex]
payloadText = ["MFLRELEASE-PAYLOAD1", product, channel, versionDecimal,
               issuedAtDecimal, expiresAtDecimal, metadataUrl, metadataSha256]
```

The Ed25519 message is the ASCII bytes `MFLRELEASE1`, one NUL byte, then the
exact canonical UTF-8 payload. This application domain is not Ed25519ctx.
All numbers are canonical nonnegative decimal strings; version starts at one.
Product/channel are 1..128 ASCII letters/digits/dot/underscore/hyphen. The URL is
1..8192 ASCII HTTP(S) characters without userinfo, controls, fragments or
backslashes; actual transport additionally validates DNS/IPv4 authority and port.
Unknown fields, versions, trailing bytes, noncanonical JSON, malformed UTF-8,
invalid key/signature encodings and unsupported data are refused, never dropped.
Verification errors do not echo remote metadata or key material.

## Trust boundary

Provision the public key separately from the untrusted origin and protect it
locally. Trusting a public key fetched from that same origin does not authenticate
the publisher. This format is project-authored, not TUF, OpenPGP or zsync metadata.
The upstream cryptography package is unaudited and not constant-time; this layer
does not upgrade those properties. It is unsuitable for side-channel-sensitive
signing without an appropriate external signing environment.

Automatic key distribution/rotation, delegation, threshold signatures and
compromised-key recovery are outside the implemented scope.

## Persistent release acceptance (native)

Run `moon run --target native examples/release-state` for signed authorization,
real USGS data delivery without artifact network requests, and a reopened-store
rollback refusal. The deterministic signing seed is public demonstration data.

Initialize ONCE in a protected local directory with
`host.initialize_release_state(path, trust)`. Initialization requires new state,
`.lock` and `.next` paths; ordinary updates never initialize missing state.
Call `host.with_release_state(path, trust, signed_bytes, now, action=...)` to
verify the release, lock the store exclusively, and save its version, payload
hash and observed clock BEFORE invoking the action. The callback gets the
`ApprovedRelease` and may return any value. Keep all update work inside it.

Reopening rejects lower versions, a different payload at the same version,
backward clocks, policy/key changes, malformed or missing state. Identical
releases may retry or resume while still valid. Callback failure keeps the
accepted version floor; accepting a release means authorizing it, not marking
its installation successful. Increase the version to refresh signed expiry.
The configured minimum version is also frozen in this store.

MFLRELEASE-STATE1 is bounded canonical UTF-8 JSON (4096 bytes maximum), exactly
`[tag, product, channel, keySha256, minimumVersion, acceptedVersion, payloadSha256,
observedUnixTime]`. Numbers are decimal strings. Initial accepted version/time
are `"0"` and the initial payload hash is empty. Nonzero versions require a
SHA-256 payload hash. Persistence writes a new `.next`, syncs and reads it back,
then replaces state. Interrupted pending data blocks ordinary actions.
`host.recover_release_state(path, trust)` explicitly validates BOTH records and
promotes pending state only if version/time do not decrease and same-version
payload does not change. Invalid candidates are preserved for inspection.

Protect the state, lock and pending files from deletion, replacement and rollback
by other software. The callback must not modify those paths. Locks coordinate
cooperating processes only. Restoring an older backup or deleting and explicitly
reinitializing state defeats this local rollback defense. There is no trusted
hardware counter, clock service or power-loss/directory-fsync durability claim.
This is a single-key/product/channel store, not a general TUF trust database.
