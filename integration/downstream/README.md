# Independent resource-maintainer application

Run from the repository root:

```text
moon run scripts/downstream_demo.mbtx
```

This is a separate module (`mfl-example/resource-maintainer`) with its own
manifest. The driver copies the application into a disposable workspace and
resolves `cn-wn/moonfetchledger` to this checkout as a workspace dependency.
It does not copy library implementation into the application and does not
publish, log in to, or require a published MoonFetchLedger on Mooncakes.
Run `moon check --target native` once to install the root module's public
third-party dependencies. The driver copies that installed dependency cache
into its temporary workspace and uses frozen resolution, avoiding repeat
downloads while still validating dependency versions. No library implementation
is copied into the consumer module.

The application accepts a stable regular binary input of 8192..16000000 bytes.
It builds two partial, offset-shifted seed files, previews the union, publishes
target metadata and authorizes it using a public TEST signing seed. It then
delivers exact content with no artifact requests, damages one stored byte,
repairs from the original input and reopens the completed signed session.
Assertions verify exact bytes, zero artifact downloads and source preservation.
The driver additionally verifies refusal of an undersized input.

For another input, use the same temporary workspace setup and run the consumer
with `moon run --target native . -- ABSOLUTE_INPUT_PATH`. A compiler and stable
MoonBit are required. This exercises local dependency adoption, not registry
installation. Deployment keys, filesystem permissions and the clock remain
the application's responsibility. The bounded demo loads its input in memory;
the library's streaming APIs have their own documented bounds.

Application and driver: project-authored Apache-2.0. The default input is the
public-domain USGS fixture documented in `fixtures/README.md` at the repo root.
