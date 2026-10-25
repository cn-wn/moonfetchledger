# Reproducible delivery checklist

This checkout is a library/tool delivery, not a Mooncakes publication. No script
below logs in, uploads a package, pushes Git or sends a competition submission.
Third-party dependency installation is separate from publishing this module.

## Reproduce

Install current stable MoonBit, Node 22 and a native C compiler. On Windows use
the MSVC developer environment, as in `.github/workflows/ci.yml`. Linux package
round-trip validation additionally needs Python 3's standard `zipfile` CLI;
Windows uses its `tar`. No Python automation code is authored or generated.

```text
moon version --all
moon update
moon run --deny-warn scripts/verify.mbtx
moon run --deny-warn scripts/package_check.mbtx
```

The first workflow checks formatting and generated-interface drift, strict
four-target compilation, actual wasm/wasm-gc/JS/native tests and all bundled
workflows including the independent downstream module. Core test counts at this
milestone are 49 per portable target and 132 native, including WebDAV tests.
Examples invoke real child CLIs and local origins; they are assertions, not
hard-coded success logs. Optional external-server verification remains separate:
see [integration setup](../integration/README.md).

The package workflow runs `moon package --frozen` locally, validates archive paths,
requires metadata/licenses/interfaces/real fixtures/downstream sources, extracts
to a new temporary directory and compares every packaged source byte. It seeds
only the installed third-party cache, then performs strict four-target checks,
wasm tests, a native delta example and the independent downstream application
from the extracted package. It requires source bytes to remain unchanged.

`_build/publish/package-check.json` is a local MFLPACKAGE1 receipt:
`[tag, archiveSha256, [[relativePath, fileSha256], ...]]`. Records are path-sorted.
The archive hash identifies this exact local zip; the sorted content records are
the deterministic source fingerprint. No cross-platform zip-byte reproducibility
claim is made. `_build` outputs and dependency caches are not committed.
This repository-oriented gate refuses archive entry names with spaces/tabs,
directory entries, links or ambiguous listing records; unsupported entries
produce a diagnostic rather than being silently omitted.

## Scope and evidence

The differentiated contribution is the receive/update/recovery layer composed
with an existing WebDAV client. [Review response evidence](differentiation-proof.md)
maps both rejections to actual workflows. [Ecosystem comparison](ecosystem.md)
records known overlaps, snapshots and uncertainty; [sources/licenses](../THIRD_PARTY_NOTICES.md)
records reused APIs, test data and method references.

Implemented: public-key-authenticated metadata, local monotonic version
acceptance, one-to-32 seed reuse, bounded candidate work, private artifact auth,
saved pause/resume, disk reconciliation and new-file verified export.
Not implemented: automated trust bootstrap/rotation, TUF or `.zsync` compatibility,
directory synchronization, shared chunk caching, installed-file replacement,
malicious-filesystem protection or a general power-loss guarantee.

Only actual successful CI jobs establish Windows/macOS runtime results. Local
Linux checks do not establish other operating-system support. Publishing,
registry installation and competition acceptance must not be inferred from a
successful local package round trip. This milestone intentionally does not
publish to Mooncakes.
