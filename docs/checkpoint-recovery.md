# Recover an interrupted checkpoint save

An interrupted checkpoint replacement can leave `artifact.mfl.next` beside the
older `artifact.mfl`. The newer file may describe additional blocks that already
reached disk. Download startup now refuses existing `.mfl.next` or `.mfl.recovering`
files instead of overwriting them. Keep the artifact and all sidecars together.

Recover a saved `.next` candidate explicitly, using the same independently trusted
identity as the original session:

```moonbit
let report = @host.recover_checkpoint(spec, "artifact.bin")
// Resume missing blocks through the normal download API.
let resumed = @host.download(spec, "artifact.bin")
```

```text
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output artifact.bin --recover-checkpoint
moon run --target native cmd/fetch -- --manifest release.json --manifest-sha256 TRUSTED_HEX --output artifact.bin
```

Inline identity arguments also work. `--recover-checkpoint` is an exclusive offline
mode: audit/adopt/export/repair, progress, credentials and download policy options
are rejected. It emits the existing deterministic MFLAUDIT1 report. No HTTP
requests occur and artifact bytes are never written or truncated.

The operation requires an existing regular lock sidecar and regular `.mfl.next`.
It acquires the exclusive cooperative lock, reads at most 16M bytes per checkpoint,
strictly decodes UTF-8 and requires the exact MFL1 schema and expected identity.
If the installed checkpoint exists, it must also parse and have the same block
layout. A missing installed checkpoint is supported, including a first-save
interruption before the artifact itself has been created.

Every recorded candidate block is reread and hashed. Missing, truncated or damaged
blocks become gaps. Installed records are independently checked too: the candidate
must preserve every installed block that still verifies against disk. A stale
candidate that loses valid recorded coverage is refused. Coverage comparisons use
sorted ranges in linear time; no performance comparison against other tools is made.
If candidate coverage is complete and the artifact exists, whole-file SHA-256 must
also match before installation. Extra bytes, unknown schema data, changed identities
and block layouts are refused rather than trimmed or translated.

On success, reconciled coverage is saved to an exclusively created
`artifact.mfl.recovering`, synced and renamed over `artifact.mfl`. Only then is
`artifact.mfl.next` consumed. Artifact and lock contents are unchanged. The report's
`invalidated` field is a sorted, distinct union of failed records from both input
checkpoints; `missing_ranges` and `confirmed_bytes` describe installed coverage.
An absent artifact is reported incomplete, including an absent zero-length object.

Validation failures preserve both input checkpoints and artifact bytes. A storage
failure during installation propagates; owned partial recovery temporaries are
cleaned when possible. If candidate removal fails after checkpoint installation,
the installed checkpoint may already be updated while `.next` remains; repeating
the operation revalidates it safely. There is no rollback or power-loss guarantee.
A missing candidate is a diagnostic, not an implicit recovery success.

Existing `.mfl.recovering` files are never automatically consumed or replaced:
preserve and inspect that interrupted recovery separately. This API does not force
an identity change, merge differing layouts, override corrupt installed metadata,
choose among arbitrary backups or discard unsupported files. Do not delete unknown
temporaries just to bypass the diagnostic. File locks protect cooperating processes
in a trusted directory, not hardlink tricks or malicious external writers.

Normal checkpoint saves also create `.next` exclusively, clean only their own
temporary after failure, and replace the installed checkpoint after syncing.
Local adoption and local repair likewise refuse checkpoint recovery temporaries.

Run `moon run scripts/checkpoint_recovery_demo.mbtx`. Using the real USGS fixture,
it obtains two valid checkpoints from successive downloads, reconstructs an
interrupted replacement with four downloaded blocks, verifies startup refusal and
input preservation, promotes coverage offline, then resumes three remaining blocks
while retaining 16384 bytes. It refuses a stale candidate after completion and
reopens with zero downloads after shutting down the origin. The manifest demo also
verifies recovery through a pinned manifest. Tests cover all 64 pairs of three-block
coverage masks, corrupt/absent content, complete SHA failures, malformed identities,
different layouts, size limits, locks, temporary ownership and installation failure.
Sources/licenses: `THIRD_PARTY_NOTICES.md`, `fixtures/README.md`.
