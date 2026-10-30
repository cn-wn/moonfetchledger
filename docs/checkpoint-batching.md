# Bounded checkpoint batching

Native receive/download, WebDAV receive, seed reconstruction and unsigned/signed
updates accept checkpoint_blocks=1..1024. The default remains one saved block.
cmd/update and cmd/release accept --checkpoint-blocks with the same bounds;
invalid values are refused before staging or release-state changes.

An opted-in batch writes at most the chosen number of blocks before syncing
data, independently reading back every block, committing coverage and replacing
one complete checkpoint. A cumulative 16 MiB of pending content also forces a
flush, possibly exceeded by the final block (at most 4 MiB). Pending state holds
prepared hashes/ranges, not a batch of content buffers. Network concurrency is
still bounded independently by parallel.

Cooperative pause, a block budget and normal completion flush a short final
batch. Saved progress callbacks run only after checkpoint installation; several
block events can describe the same saved coverage snapshot. Callback errors
propagate and retain the saved batch. An abrupt kill, network/storage error or
failed checkpoint may leave unrecorded bytes: retain the session and resume;
those bytes are not trusted or reported as saved coverage. At most one pending
batch must be repeated. Existing explicit pending-checkpoint recovery still
applies. This is not a power-loss or hostile-filesystem guarantee.

Run:

    moon run --target native examples/batched

The public-domain 28008-byte USGS fixture is delivered through a controlled local
source in 876 blocks of 32 bytes. Actual saved-coverage observations must change
from 876 groups to 14 with batches of 64, while final artifact/checkpoint bytes
and verified exports are identical. This measures save groups, not HTTP traffic
or throughput. A white-box storage test additionally compares installed metadata
volume for 1025 tiny blocks and asserts batch readback failure preserves the old
checkpoint. The default and all old checkpoint formats are preserved.
