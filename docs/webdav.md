# Extend WebDAV downloads with verified block repair

This native package composes **q2316367743/webdav@0.1.0** and its published
**q2316367743/moonhttp@0.5.0** transport interface. The upstream performs WebDAV
operations, URL/path encoding, Basic authentication, TLS and HTTP framing. This
project does not port or fork those implementations. The shared ledger/host adds
disk readback, confirmed sparse coverage, checkpoint reconciliation, audit and
selective repair. [Comparison and boundaries](ecosystem.md).

## Public workflow

Import `cn-wn/moonfetchledger` as `ledger`, `cn-wn/moonfetchledger/host` as `host`,
`cn-wn/moonfetchledger/webdav` as `dav`, and `q2316367743/webdav` as `upstream`.
In an async application, with a trusted `spec` and a transient upstream `config`:

```moonbit
let client = @upstream.create_webdav_client(config)
// First use: the existing client downloads to a new local path.
client.download_to_path(path="/artifact.bin", local_path=output)
// First adoption requires the entire file to match the independently trusted SHA.
@host.adopt(spec, output, chunk_size=65536)
// On later invocations, audit retained content without changing it or networking.
let report = @host.audit(spec, output)
let source = @dav.Source::new(spec, config, "/artifact.bin")
let repaired = source.receive(output)
// Complete repair includes full SHA-256 verification, before export to a new path.
@host.export_verified(spec, output, new_destination)
```

Keep output, `.mfl` and `.mfl.lock` together. Adopt only once for a new checkpoint;
adoption refuses existing checkpoints and mismatching files. It cannot infer a
trusted block ledger from an arbitrary pre-existing corrupt file. Later calls to
`Source.receive` can start fresh or reuse a compatible MFL1 session. They first
reread its recorded blocks; only missing/bad blocks generate requests. A block
budget or shared `PauseSignal` drains/saves the current batch and permits a later
call with a newly constructed Source/rotated credentials. Complete reopen makes
zero requests. Audit, checkpoint recovery, local-backup repair and export retain
their existing host APIs and on-disk format.
When local progress is missing but an independently authenticated complete block
reference exists, audit_with_reference can inspect the damaged artifact without
creating sidecars. adopt_with_reference creates a NEW checkpoint from actual
matching blocks, after which the same Source.receive repairs only the gaps.
Existing checkpoints and temporaries are refused. This extra trusted input is
required; arbitrary damaged content still cannot establish its own block hashes.
See [block references](block-reference.md) and the
[actual upstream comparison](differentiation-proof.md).
The upstream downloader does not acquire `.mfl.lock`: do not run it concurrently
against an adopted output. Use the managed receive workflow or a new download
path when changing the artifact; coordinate any other writer explicitly.

`host.receive_from(spec, output, fetch_range=...)` is the shared native storage
boundary for other clients. Its callback returns `ReceivedBlock` with actual
bytes/status/ETag/range/total/encoding. The ledger validates these before content
writes. Callbacks may run concurrently and must bound reads, close their resources
and refuse unsupported transport metadata. The storage layer does not retry calls.
The existing `host.download` API remains compatible and uses this same workflow.

## Response and input contract

- `base_url` plus the upstream percent-encoded path must equal `spec.resource`
  exactly. URL userinfo, base queries/fragments and non-HTTP(S) URLs are refused.
  Hosts must be nonempty and explicit ports canonical decimals in 1..65535;
  overflow, empty ports and leading-zero normalization are refused before I/O.
- Object identity requires known length, strong quoted ETag and an independently
  trusted SHA-256. An ETag, filename or successful download is not that trust source.
- **Upstream range limit is retained:** at most 2147483647 object bytes. This
  adapter does not promise the core's larger Int64 address space. Blocks are
  1..4194304 bytes; the existing 100000-block limit still applies.
- Credentials use the upstream transient configuration. HTTPS is required when
  credentials are supplied. Explicit `allow_loopback_auth=true` permits only
  `127.0.0.1` HTTP tests; it is not a production downgrade. URL/credential binding
  is checked before file/session creation. Timeout is 1..120000 ms per wire stage.
- The request uses upstream `get_file(range=..., conditions=If-Match)`. A private
  implementation of the upstream open `Transport` trait delegates actual I/O to
  `HttpConnTransport`, forcing `Accept-Encoding: identity` before sending.
- That guard inspects raw metadata before upstream buffering: only 206 with the
  exact ETag, canonical range and known total is accepted. Content-Length, when
  present, must match the block. Encoded and multipart representations, unknown
  totals, changed versions, redirects, 200 fallback and extra/short bodies fail.
  No redirect destination receives a follow-up request. The body read is bounded
  to the requested block plus one detection byte; it is closed on every exit.
- `get_file` itself does not expose Content-Encoding, so a result-only wrapper
  would be insufficient. The guard checks it before the client can hide it or
  decode/buffer unsupported content. Result metadata then passes ledger checks too.
- Request failures produce a static actionable `SourceError::RequestFailed`
  without reflecting server/parser text or credentials. Invalid bindings produce
  `SourceError::InvalidConfig`. Ledger, storage and observer errors propagate.
  File/session progress saved before an error remains available for another call;
  recovery may update metadata to remove invalid records before a request fails.

No automatic redirects, retry policy, arbitrary headers, WebDAV lock negotiation,
upstream cache migration, modelhub adapter, browser I/O or vendor interoperability
certification is implemented here. These are separate from the upstream clients'
own capabilities. Checkpoints need trusted storage and cooperating file locks;
there is no power-loss or protection-from-malicious-writer guarantee.

## Reproducible evidence

Run `moon run --target native examples/webdav`. It uses the published client,
actual loopback sockets and the 28008-byte public-domain USGS fixture. Its finite
test endpoint implements only PUT/GET/OPTIONS, not a full RFC 4918 server:

1. Upstream upload, capability query and original full download; trusted adoption.
2. Change one interior byte while preserving file size; offline audit retains
   23912 bytes and locates `[8192,12288)` without changing file/checkpoint bytes.
3. Refuse an encoded response while preserving artifact bytes, then repair that
   single block through upstream range GET and verify full SHA-256.
4. Damage two nonadjacent blocks; pause after one repair and construct a fresh
   Source to repair only the remaining one. Export a byte-identical artifact.
5. Delete the demonstration checkpoint and change one byte without changing length.
   Call upstream download_to_path_resume: a valid 416 with equal total length
   returns successfully while content remains damaged, matching its prefix contract.
   Ordinary full-file adoption refuses the digest mismatch. Independently pinned
   block records audit/rebuild a sparse checkpoint retaining 23912 bytes with no
   artifact writes or requests. The same Source then repairs exactly [16384,20480),
   while full-download count remains one.
6. Stop the endpoint and reuse complete coverage with zero further downloads.

Tests additionally cover all eight three-block coverage masks, short final blocks,
preflight integer/URL/auth/timeout boundaries, conditional/auth request headers,
status/range/ETag/encoding/length/body refusals, credential-safe diagnostics and
retry after refusal. `scripts/verify.mbtx` runs this example in the native stage
on Linux, macOS and Windows CI. Test results and actual platform evidence belong
in [validation.md](validation.md); configuration is not proof of a passing run.

Sources and licenses: [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

An additional [WsgiDAV/Cheroot integration](../integration/README.md) runs an
unmodified external server with pinned public test dependencies. It checks real
PROPFIND, HTTP ETag, upstream full download, reference-based one-block repair,
verified export and actual stale If-Match 412 refusal. Its separate Linux CI job
complements the finite fixture; this is one server configuration, not general
vendor certification.
