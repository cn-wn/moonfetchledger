# Toolchain and standalone automation

Use the current stable MoonBit distribution. The October 23, 2026 stable update
requires script dependency imports in leading `----` frontmatter for clean
`--deny-warn` compilation. All shipped `.mbtx` workflows use that format.
Older Moon executables that do not recognize it cannot run these scripts;
update the toolchain as a whole rather than suppressing `unfenced_import`.

```text
moon version --all
moon update
moon run --deny-warn scripts/verify.mbtx
```

The verification driver checks script formatting and compiles every child script
with `--deny-warn`. CI applies the same flag to the driver and the separate real
WsgiDAV workflow. Runtime fixture assertions are unchanged by the import-header
migration. This catches script warnings that the previous non-strict driver
invocations could leave unnoticed even when library checks passed.

The existing duplicate async/internal/c_buffer import message and platform C
compiler warnings originate in upstream tooling/dependencies and are recorded
separately; no dependency source or warning policy is patched to hide them.
This workflow performs local checks only; it does not publish packages.
