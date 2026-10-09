# Offline HTTP and disk recovery

Run from the repository root, with moon and the native platform compiler on PATH:

```text
moon update
moon run scripts/recovery_demo.mbtx
```

No credentials, public server or private infrastructure is needed. The script
serves the bundled unmodified USGS CSV on an ephemeral loopback port. It launches
the generic native downloader as separate child processes, using trusted fixture
length, ETag and published snapshot SHA-256. Temporary files are cleaned up.

1. Download three 4096-byte blocks. The server gates completion to reverse arrival
   order. The CLI persists three confirmed records and exits with a controlled
   pause. This is a process restart test, not a claim of a tested hard kill.
2. Modify a confirmed byte on disk. Start a fresh CLI process. It reads all
   recorded blocks, invalidates block zero and retains 8192 correct bytes.
3. Inspect actual HTTP requests: only blocks 0,3,4,5,6 are fetched. Blocks 1 and
   2 are preserved. Compare every final byte with the real snapshot; the CLI also
   verifies the trusted whole-file SHA-256 before declaring completion.
4. Reopen a completed session: no HTTP requests and the checkpoint is identical.
5. Return a wrong ETag before writing. The CLI fails, leaves an empty output and
   resumable checkpoint. A new process succeeds after the fixture origin recovers.

Expected salient output:

```text
paused: confirmed=12288 fetched=3 retained=0 invalidated=0
complete: confirmed=28008 fetched=5 retained=8192 invalidated=1
refetched corrupted/missing block [0,4096)
offline HTTP/disk recovery verified: reverse arrivals, independent processes, selective refill, stable checkpoint, bad-response refusal and retry
```

## Download your own artifact

Use actual metadata from a trusted source; replace all uppercase values:

```text
moon run --target native cmd/fetch -- --url URL --output PATH --length LENGTH --etag QUOTED_STRONG_ETAG --sha256 LOWERCASE_SHA256 --chunk-size 65536 --parallel 4
```

The ETag argument includes literal surrounding double quotes. Shell quoting must
preserve them. `--help` lists options. `--stop-after-blocks N` returns a successful
controlled pause. Omit it on the next invocation to finish. Unknown/duplicate
options fail. Error exits do not declare completion.

Retain PATH, PATH.mfl and PATH.mfl.lock. Do not delete the persistent lock sidecar
while another process may be active. Choose a new output path to restart with a
different object; the tool never silently discards an old identity or truncates
extra bytes. A restored session uses the block size recorded in its checkpoint.
The directory must be trusted, and other programs must not modify active output.

The host accepts HTTP/HTTPS URLs and uses the upstream client with normal TLS
verification. This offline demo validates HTTP; HTTPS against public origins is
not independently verified here. Redirect following, authentication, proxies,
compression, automatic restart on 200 and built-in network retries are unsupported.
Each block request has a 30-second timeout. Checkpoints use file sync plus replacement
rename; directory metadata is not synced, so power-loss durability is not claimed.
