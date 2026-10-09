# Private artifact downloads with transient Bearer credentials

Provide a trusted object identity and an independently obtained credential:

```moonbit
let auth = @host.BearerAuth::new(spec.resource, token)
let report = @host.download(spec, output, auth~)
```

The credential is bound to the exact resource string. Passing it for another URL
fails before session files are created. A refreshed token creates a new BearerAuth
for the same resource; object length, ETag, digest and checkpoint identity remain
unchanged. Resume reads existing disk coverage and fetches only missing blocks.
BearerAuth has no public secret field, Debug implementation or serialization.
It is separate from ObjectSpec, progress events and checkpoints.

CLI downloads use `--bearer-env VARIABLE_NAME`. Supply that variable through your
process environment or secret manager; the CLI accepts no token-value argument.
The variable name must be an ASCII identifier of at most 128 characters. Unset,
empty or malformed tokens fail before filesystem changes. Offline modes reject
credential options and do not need a token. A complete cached session can also be
reopened without authentication because it makes no network request.

The supported token syntax follows the Authorization Bearer format described in
[RFC 6750 section 2.1](https://www.rfc-editor.org/rfc/rfc6750#section-2.1): ASCII
letters, digits, `-._~+/`, followed by optional `=` padding; 1..4096 characters.
Whitespace, controls, Unicode, quoted values and interior padding are refused.
The code is project-authored; no RFC prose or code was copied.

Default transport is HTTPS using the async client's system trust roots. Supported
URLs have ASCII DNS/IPv4 authority and optional canonical ports 1..65535, without
userinfo, fragments, backslashes, spaces or controls; URL length is at most 8192.
IPv6 authority, IDNA host conversion and raw Unicode paths are explicitly outside
this adapter's authenticated URL boundary. Use already encoded ASCII paths. The
URL is not rewritten. Do not put credentials in URL/ETag/object metadata: those
identity fields are intentionally saved in the recovery checkpoint.

For local tests only, `BearerAuth.new(..., allow_loopback_http=true)` or CLI
`--allow-loopback-auth` permits HTTP to literal `127.0.0.1`, optionally with a port.
Other HTTP hosts, including localhost, are refused. This explicit test exception
does not claim TLS protection or full OAuth protocol conformance. TLS certificate
verification is delegated to the pinned async client and not disabled here;
the reproducible loopback demo verifies workflow semantics, not a live TLS origin.

Every original range request and supported transient retry carries Authorization,
Range, If-Range and identity encoding. The pinned client's single-request API does
not follow redirects; all non-206 responses still fail, including 3xx. A 401/403
fails immediately with an instruction to obtain a fresh credential; retry settings
do not repeat it. There is no OAuth issuance, automatic refresh, cookie session,
proxy authentication, general header injection or redirect forwarding API.

Authenticated parser/transport failures use a fixed diagnostic instead of echoing
untrusted input that could reflect a token. Known adapter errors and cancellation
retain their existing handling; caller-defined observer errors remain caller-owned.
Credentials still live in process memory and the caller's environment: this API
does not promise memory erasure or prevent operating-system/process inspection.

Run `moon run scripts/auth_demo.mbtx`. A loopback server uses fabricated public
test credentials and real USGS data. The CLI pauses after two blocks, receives a
single 401 after credential rotation, resumes five blocks while retaining 8192
bytes, checks exact data and checkpoint preservation, and audits/reopens offline.
It also verifies 403, no redirect contact, a malformed wire header reflecting the
test credential, authenticated 503 retry, invalid-token refusal and absence of
the test credentials from CLI output/checkpoints. No private infrastructure or
real credentials are needed. Sources/licenses: `THIRD_PARTY_NOTICES.md`.
