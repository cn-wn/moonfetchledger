# Real WebDAV server interoperability

This optional integration runs **WsgiDAV 4.3.5 with Cheroot 11.1.2**, rather than
the finite in-project PUT/GET fixture. It uses a disposable share, anonymous
loopback HTTP and the existing public-domain USGS data. The published
q2316367743/webdav 0.1.0 client performs actual PROPFIND, GET and PUT requests;
MoonFetchLedger adds integrity audit, new sparse-checkpoint adoption and repair.

## Reproduce on Linux

With Python 3.13, a C compiler and stable MoonBit installed, from the repo root:

```text
python3.13 -m venv /tmp/mfl-webdav-venv
/tmp/mfl-webdav-venv/bin/python -m pip install -r integration/requirements.txt
/tmp/mfl-webdav-venv/bin/python -m pip check
MFL_WSGIDAV=/tmp/mfl-webdav-venv/bin/wsgidav moon run --deny-warn scripts/wsgidav_demo.mbtx
```

All eleven resolved server packages are pinned in requirements.txt. They are
optional test tools installed in the separate environment, not MoonBit module
dependencies or vendored code. MFL_WSGIDAV selects an executable; the default is
wsgidav on PATH. The harness requires its exact 4.3.5 version. CI has a separate
Ubuntu interop job using Python 3.13 and the same pins. The standard three-OS job
does not require Python or an external server.

The MoonBit script chooses a temporary loopback port, launches the unmodified CLI
with --no-config, waits for bounded readiness and runs the native example. Its
task group terminates the owned server on success or failure; temporary client
files/share are removed and failures print the captured server log. Before any
artifact workflow or PUT, the client verifies a per-run share marker; another
service winning the port race must not receive the workflow's writes. The harness
also checks a wrong-marker refusal and unchanged shared fixture. This prevents
accidental endpoint confusion, not a malicious local service copying the marker. No Docker,
credentials, private infrastructure or pre-existing share is needed.

## What is checked

1. PROPFIND reports the original file length. A one-byte range GET returns 206,
   correct Content-Range and a real quoted HTTP ETag. WsgiDAV's DAV:getetag text is
   deliberately not substituted for an HTTP entity-tag header.
2. The original upstream full download matches all 28008 fixture bytes. The
   independently known whole SHA-256 gates publisher block reference creation.
3. Same-size corruption without a local checkpoint is audited read-only. Exactly
   23912 bytes are retained; new sparse checkpoint adoption changes no artifact
   bytes. Source.receive commits only [8192,12288), then validates the complete
   SHA-256 and exports identical bytes. The complete checkpoint equals the
   immutable reference byte-for-byte.
4. PUT publishes a different-length remote version. The real server changes its
   ETag and rejects a stale If-Match range with HTTP 412. The ledger's stale source
   also refuses a subsequently needed block with a sanitized error and preserves
   every artifact byte. Reconciliation may save the remaining valid coverage;
   this is not a rollback of checkpoint changes.

This proves the tested anonymous HTTP configuration on WsgiDAV/Cheroot. It does
not certify all WebDAV products, TLS, authentication, proxies, multi-range GET,
distributed locks or power-loss recovery. WsgiDAV's inode/mtime/size ETag is a
version validator, not a content digest; independent trusted SHA-256 remains
required. Do not run examples/wsgidav against another user's loopback share: its
PUT changes the named test artifact. Use the owning harness above.

## Sources and licenses

No server implementation or upstream test suite was copied. The harness and
native scenario are project-authored Apache-2.0; the USGS fixture's provenance is
in fixtures/README.md. Installed dependencies retain their own notices:

| Test dependency | License | Source |
| --- | --- | --- |
| WsgiDAV 4.3.5 | MIT | https://github.com/mar10/wsgidav |
| Cheroot 11.1.2 | BSD-3-Clause | https://github.com/cherrypy/cheroot |
| bcrypt 4.3.0 | Apache-2.0 | https://github.com/pyca/bcrypt |
| defusedxml 0.7.1 | PSF-2.0 (metadata: PSFL) | https://github.com/tiran/defusedxml |
| jaraco.functools 4.6.0 | MIT | https://github.com/jaraco/jaraco.functools |
| Jinja2 3.1.6 | BSD-3-Clause | https://github.com/pallets/jinja |
| json5 0.17.3 | Apache-2.0; benchmark data includes MIT terms | https://github.com/dpranke/pyjson5 |
| MarkupSafe 3.0.4 | BSD-3-Clause | https://github.com/pallets/markupsafe |
| more-itertools 11.2.1 | MIT | https://github.com/more-itertools/more-itertools |
| passlib 1.7.4 | BSD-3-Clause plus bundled third-party terms | https://passlib.readthedocs.io/en/stable/copyright.html |
| PyYAML 6.0.3 | MIT | https://github.com/yaml/pyyaml |

The passlib distribution additionally documents Beer-Ware, DES custom, jBCrypt
ISC-like and EFF word-list terms; consult its installed LICENSE. This integration
does not copy or redistribute these packages. Package versions/licenses and server
behavior were checked against installed distributions on 2026-10-19.
