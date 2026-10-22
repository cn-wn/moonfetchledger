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

## Signed publisher-to-consumer workflow

`host.write_signed_release(descriptor, private_seed_file, new_descriptor)` reads
at most 32 bytes and requires an exact raw Ed25519 seed; it never replaces a key,
descriptor or pre-existing `.next`. `host.load_release_trust` loads an independently
provisioned exact raw 32-byte public key. These are binary key files, not hex,
PEM or OpenSSH containers. Provision a fresh private seed/public key pair offline
using an appropriate key-generation environment or the existing Ed25519 library;
this project does not generate deployment keys or change their permissions.

`host.load_release` and `host.fetch_release` return UNTRUSTED announcement bytes,
not authorization. Reads are bounded to 16384 bytes. HTTP requires an unencoded
200 without Content-Range; redirects, oversized declared/streamed bodies and
length changes fail. Timeouts are 1..120000 ms; transport errors redact URLs.

`host.update_signed_release(bytes, trust, state, staging, now=trusted_unix_time,
seed=old, export_to=new_ready, ...)` verifies the signature/time/scope, validates
controls and state-path separation, and locks/records acceptance before fetching
the signed metadata URL. Its SHA-256 must match the signed pin before parsing.
Then the existing seed/receiver/export workflow handles actual bytes. A valid
release remains accepted even if metadata or artifact transfer fails. Retry that
same release, using `resuming=true` only if staging/checkpoint/lock already exist.
A higher version remains allowed; an older one cannot request metadata/artifact
bytes through this workflow. Signature validity is checked at operation start,
not continuously during an already authorized transfer. The library's clock is
caller-supplied; the CLI uses the actual system clock with no override option.

Native `cmd/release` implements signing, explicit initialization/recovery and
public-artifact updates. It does not accept consumer-supplied identity/digest or
chunk overrides. `--metadata LOCAL_DELTA` is an explicit offline alternative to
the signed URL; its bytes must still match the signed pin. Private-artifact callers
can compose the lower-level state callback and authenticated HTTP/WebDAV APIs.

```text
moon run --target native cmd/release -- --help
moon run scripts/signed_update_demo.mbtx
```

For a deployment, publish target metadata with `cmd/update --publish` first and
substitute real offline keys, URLs, monotonic version counters and Unix times:

```text
moon run --target native cmd/release -- --sign --private-seed-file publisher.seed --descriptor v2.release --product mydata --channel stable --version 2 --issued-at ISSUED_UNIX --expires-at EXPIRES_UNIX --metadata-url https://example.test/v2.delta --metadata-sha256 PUBLISHED_DELTA_PIN
moon run --target native cmd/release -- --init-state --public-key-file publisher.pub --product mydata --channel stable --state release-state
moon run --target native cmd/release -- --release-url https://example.test/v2.release --public-key-file publisher.pub --product mydata --channel stable --state release-state --seed v1.bin --output staging-v2 --export-to ready-v2
moon run --target native cmd/release -- --release-url https://example.test/v2.release --public-key-file publisher.pub --product mydata --channel stable --state release-state --resume --output staging-v2 --export-to ready-v2
```

Keep `release-state`, `.lock` and any interrupted `.next` across runs. Initialization
is not an update flag. Resolve a pending save explicitly with `--recover-state`
and the same key/product/channel/minimum version. Canonical MFLSIGNED1 JSON lines
report signed, initialized, state-recovered, paused/complete and exported phases.
The private seed contents are never printed or passed as a command-line value.

The self-contained demo uses actual child command processes and a real HTTP
origin with the existing USGS-derived synthetic v2. It verifies signature/expiry
refusal before state changes, metadata tampering without staging writes, 11655
bytes reused, a one-block pause at 15751 bytes, a validly signed old-version
refusal before metadata/artifact requests, another-process resume downloading
only the remaining two blocks, exact 23943-byte delivery, preserved old/key files,
stopped-origin zero-download reopen and explicit interrupted-state recovery.
Public test keys are used only within its temporary directory.
