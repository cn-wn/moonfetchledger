# Offline disk audit and gap planning

`host.audit(expected, output)` inspects an existing session using read-only file
handles and a shared lock on the existing `.mfl.lock` sidecar. It does not create,
download, truncate, repair or save files. Keep output, `.mfl` and `.mfl.lock`
together; checkpoint and lock are required. An absent output is reported explicitly
without creating it. Filesystem access timestamps can change on reads.

The expected ObjectSpec must come from a trusted release manifest or another
independent source. Reading identity and expected hash from the same unsigned
checkpoint does not establish authenticity. Resource is an identity string here;
audit never contacts its URL. Only cooperating downloaders honor the shared lock.
Use a trusted directory without external writers, just as for download recovery.

Three workflows:

1. Before activating a cached dataset in CI, audit with the release's URL, length,
   ETag and SHA-256. Promote only when `report.complete` is true. Full coverage
   triggers streaming whole-file verification; a wrong final digest raises
   LedgerError.DigestMismatch instead of reporting success.
2. Before reconnecting on a metered link, inspect `confirmed_bytes` and
   `missing_ranges` to estimate required transfers. Gaps include damaged blocks
   and unrecorded ranges, sorted and merged at adjacent boundaries. Disk length
   is reported separately and never used as proof of coverage. Pass the same files
   to download later; audit does not save its reconciled in-memory state.
3. When diagnosing a damaged retained artifact, inspect `invalidated` to identify
   exactly which recorded blocks no longer match readback. Repeat the audit for a
   deterministic report while preserving the original checkpoint as evidence.

Generic command (replace placeholders with independently trusted values):

```text
moon run --target native cmd/fetch -- --audit --url URL --output PATH --length N --etag QUOTED_ETAG --sha256 HEX
```

Audit mode rejects download-only options, including chunk size and retry settings.
It emits one JSON report and exits successfully for valid complete **or incomplete**
sessions. Consumers must inspect `complete`; an incomplete report is not an
activation authorization. Invalid metadata, schema, I/O, competing locks, trailing
data and final digest mismatch fail with diagnostics. Extra bytes are refused,
never silently ignored. Read failures propagate rather than becoming missing data.

MFLAUDIT1 is exactly:

```text
["MFLAUDIT1",complete,outputPresent,storedBytesDecimal,confirmedBytesDecimal,[[startDecimal,endDecimal],...],[[invalidatedStartDecimal,invalidatedEndDecimal],...]]
```

Offsets use half-open ranges and decimal strings. `AuditReport.to_json` exports
this versioned array in deterministic order; it is not a checkpoint import format.
Returned arrays belong to the report and do not mutate a live Session. The portable
`Session.unconfirmed_ranges` provides the same coalesced projection for custom
adapters; it includes reserved ranges and requires completed restoration first.

Run `moon run scripts/recovery_demo.mbtx` to reproduce audits on the bundled real
USGS dataset before repair and after completion. The demo verifies exact JSON,
lossless JSON round trips, no network requests and byte-for-byte preservation of
output and sidecars. Native tests also cover missing/truncated files, absent empty
output, shared locks, malformed checkpoints, wrong identity and wrong final hash.
