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

At this milestone signature verification has a configured minimum version but
no persistent highest-version memory. Signed old versions inside their validity
window can still replay unless the application remembers a version floor.
Automatic key distribution/rotation, delegation, threshold signatures and
compromised-key recovery are outside the implemented scope.
