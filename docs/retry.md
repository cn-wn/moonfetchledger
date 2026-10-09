# Bounded block retries

The native `host.download` and `cmd/fetch` support `max_attempts` (CLI
`--max-attempts`), `retry_delay_ms` and `request_timeout_ms`. Defaults are 1 total
attempt, 200 ms wait and 30000 ms per request. Valid limits are 1..8 attempts,
0..30000 ms wait and 1..120000 ms request timeout. Invalid settings fail before
creating files. The attempt budget applies separately to each reserved block.

Example options for the generic downloader:

```text
moon run --target native cmd/fetch -- --url URL --output PATH --length N --etag QUOTED_ETAG --sha256 HEX --max-attempts 3 --retry-delay-ms 500 --request-timeout-ms 30000
```

Only HTTP 429, HTTP 503 and request timeout are retried. Each attempt uses the same
Range, If-Range and identity encoding. The client closes before waiting; no bytes
are written until a complete valid 206 body is available. The configured delay is
fixed, not exponential. A supported `Retry-After` increases the wait to at least
the server's decimal seconds. Date-form values, malformed/duplicate hints and waits
above 30 seconds are rejected explicitly rather than ignored or clamped. HTTP-date
support is not implemented. Network/DNS/TLS errors, other status codes, malformed
or extra bodies, version/range/encoding changes, storage failures and cancellation
propagate immediately. Retrying storage writes would break this contract.

`RetryExhausted(range, attempts, reason)` identifies the failed block and consumed
budget. Other concurrently completed blocks can remain committed. Keep output and
sidecars and restart with the same trusted identity; uncommitted reservations are
not persisted. `downloaded_blocks` counts committed blocks, not HTTP attempts.

Run `moon run scripts/recovery_demo.mbtx` for a real-data, offline demonstration:
503 then 429 then valid payload; exact three-attempt exhaustion and later restart;
request timeout and retry; changed ETag refusal without retry. The fixture and
checkpoint are inspected to prove unsuccessful attempts do not record coverage.

Protocol sources: [RFC 9110 Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3)
and [RFC 6585 429](https://www.rfc-editor.org/rfc/rfc6585.html#section-4).
These references informed behavior; implementation and tests were written for this
project without copying RFC prose or external retry implementations.
