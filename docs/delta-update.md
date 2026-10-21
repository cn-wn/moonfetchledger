# Cross-version reuse from an untrusted old file

This native workflow publishes a target index, scans an old file at arbitrary
byte offsets and reconstructs verified blocks into a NEW MFL1 session. Existing
HTTP/WebDAV receivers or a verified local backup can fill its remaining gaps.
The old file needs neither a checkpoint nor a trusted old digest and is not modified.

```text
moon update
moon run --target native examples/delta
```

The example derives a test v2 from the real public-domain USGS snapshot by
inserting, removing and reordering data, then corrupts the seed. It checks moved
block reuse, actual disk audit, offline completion from a verified publisher copy,
and exact v2 export while preserving v1. The derived v2 is test data, not a second
USGS release. Network receivers consume the same generated checkpoint.

## Public workflow

1. `host.write_delta_reference(spec, target, metadata, chunk_size=...)` verifies
   the entire target SHA-256 before publishing to a new path. Distribute its
   returned exact-byte SHA-256 pin through an independent trusted channel.
2. `host.load_delta_reference(metadata, pin)` checks the pin before parsing the
   target identity and complete block index. An untrusted adjacent pin provides
   no publisher authenticity.
3. `host.reuse_from_seed(reference, old_file, new_staging)` scans old content,
   rechecks selected bytes before copying, syncs/readbacks and saves an ordinary
   MFL1 checkpoint after each copied block. It reports reused bytes/blocks and
   missing ranges. Existing output and sidecars are refused.
4. Complete through `host.download(reference.spec, staging)` or WebDAV Source;
   these keep existing pause/restart and final SHA-256 requirements. Alternatively
   use `repair_from_local` when a fully verified backup is available.
5. `host.export_verified` delivers the fully verified file to a new path.

Portable `DeltaIndexer` takes exact sequential target blocks; `finish` requires
the whole trusted digest. `DeltaReference.scanner()` accepts arbitrary
`SeedScanner.push(Bytes)` segments and returns an immutable SeedPlan from `finish`.
`matches()` returns a fresh target-sorted snapshot. The first strong source match
wins; repeated target blocks may share one source range. The short final block is
searched at its actual length. Finish is idempotent and later input is refused.
`Session.reserve_range` reserves one exact aligned block; `prepare_reuse` validates
lease ownership, target identity/layout and SHA-256 before writing old-file bytes.

## Format, bounds and failure behavior

MFLDELTA1 is exactly:

```text
["MFLDELTA1", identityManifestText, completeMFL1Text, [rollingUInt32Decimal, ...]]
```

Each checksum is a canonical decimal string, one per target block. Two 16-bit
rolling sums only select candidates; SHA-256 confirms each match. Collisions never
authorize copying. Parsing rejects unknown versions, extra fields, invalid UTF-8,
partial block records, mismatched identity and noncanonical/out-of-range numbers.
Inputs and publication are capped at 16000000 bytes. Writers are canonical;
loaders authenticate exact input first, and reserialization normalizes whitespace.
Existing MFL1 bytes and receiver contracts do not change.

The scanner holds at most two target-sized windows (up to 4194304 bytes each)
plus indexes for at most 100000 blocks. Native reads are 65536 bytes. Weak hits can
require full block hashing; no constant-time/performance advantage is claimed.
Encrypted or recompressed releases may reuse nothing and need full downloading.

One regular seed and a new staging path are supported. No directory updates,
shared chunk cache, installed-file replacement, truncation or deletion of foreign
metadata. Errors retain owned partial staging/checkpoint/lock for normal receiver
recovery; seed staging itself requires a new path. Seed cooperative locks are
respected; callers must exclude unrelated writers and filesystem substitution.
Whole-file verification remains mandatory before delivery. No power-loss claim.
Core supports wasm/wasm-gc/JS/native; file operations require native. Receiving
adapter URL/authentication/size limits still apply.

## HTTP metadata and complete update workflow

`host.fetch_delta_reference(url, trusted_pin, request_timeout_ms=...)` fetches
public metadata into bounded memory without filesystem writes. HTTP 200,
identity encoding and no Content-Range are required; redirects are refused.
Declared or streamed bodies exceeding 16000000 bytes fail, and SHA-256 is checked
before parsing. Timeouts are 1..120000 ms. Errors do not echo metadata URLs.
This distributes metadata with an independently trusted pin; a server supplying
both bytes and an untrusted pin does not establish authenticity.

`host.update_from_seed(reference, staging, seed=old, export_to=new_ready, ...)`
performs initial reuse, existing HTTP reception and verified export. It supports
parallelism, a download-block budget, bounded retries/timeouts and optional bound
BearerAuth through the existing receiver. Resume with `resuming=true` and no seed;
it requires existing staging/checkpoint/lock and revalidates stored coverage.
The saved layout is preserved on resume, including another compatible receiver's
layout. Paused operations do not publish ready output. Invalid controls and occupied
delivery paths fail before staging writes. Completion requires whole-target
verification; v1 and previous ready files are never replaced. Retain partial
progress after errors and explicitly resume.

Run the CLI help or the self-contained actual-process demonstration:

```text
moon run --target native cmd/update -- --help
moon run scripts/delta_update_demo.mbtx
```

For your own release, substitute actual identity data and independently trusted pins:

```text
moon run --target native cmd/update -- --publish --source v2.bin --metadata v2.delta --url https://example.test/v2.bin --length 123456 --etag '"v2"' --sha256 TRUSTED_WHOLE_SHA256
moon run --target native cmd/update -- --metadata-url https://example.test/v2.delta --metadata-sha256 INDEPENDENT_TRUSTED_PIN --seed v1.bin --output staging-v2 --export-to ready-v2
moon run --target native cmd/update -- --metadata v2.delta --metadata-sha256 INDEPENDENT_TRUSTED_PIN --resume --output staging-v2 --export-to ready-v2
```

Choose exactly one of `--metadata`/`--metadata-url` and one of `--seed`/`--resume`.
Consumer chunk-size and inline identity overrides are refused. Publisher output
prints its byte pin; copying it adjacent to a download is not an independent
trust channel. Canonical MFLUPDATE1 JSON lines describe publication, seeding,
paused/complete reception and verified export. The CLI handles public artifacts;
use the library's optional BearerAuth for private artifacts. Metadata and target
URLs require ASCII DNS/IPv4 authorities, canonical ports, no userinfo, fragments,
backslashes or `@` characters; IPv6 authorities are unsupported here.

The demo starts an actual HTTP origin and separate command processes. The derived
v2 is 23943 bytes: 11655 are reused and three 4096-byte gaps remain. One download
is saved before pause; a damaged saved block is detected on resume and a changed
ETag is refused without content writes. A later process finishes and exports exact
v2 bytes. Bad pins/options preserve inputs. Complete reopen uses local metadata
after the origin stops with no artifact requests. The optional WsgiDAV integration
also publishes/fetches actual metadata and repairs these cross-version gaps through
the published upstream WebDAV client.

Release signatures, trust-anchor bootstrap, key rotation, anti-rollback, shared
chunk caching and installed-file replacement remain unimplemented. This milestone
addresses cross-version reuse and a pinned update workflow, not all review gaps.

## Sources

The rolling/strong matching workflow references the public
[zsync specification](https://github.com/cph6/zsync/blob/master/SPEC.md).
No upstream code/tests were copied. This project-authored Apache-2.0 format and
implementation do not read `.zsync` or claim protocol compatibility. See
THIRD_PARTY_NOTICES.md, fixtures/README.md and [ecosystem boundaries](ecosystem.md).
