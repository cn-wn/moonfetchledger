# Sources and licenses

No implementation was copied from the comparison projects.

Cross-version seed reuse references the public rolling/strong matching workflow
in https://github.com/cph6/zsync/blob/master/SPEC.md (zsync project: Artistic-2.0).
No zsync code, prose or tests were copied; MFLDELTA1 is a separate format, not a
zsync port or compatibility layer. Its indexer, scanner, storage integration and
test cases are project-authored Apache-2.0. examples/delta derives an explicitly
synthetic v2 by insertion/removal/reordering of the existing public-domain USGS
fixture; it is not presented as another actual USGS release.

The bounded HTTP metadata loader, update orchestrator, cmd/update CLI and its
actual-process workflow tests are project-authored Apache-2.0 and reuse the pinned
async HTTP/filesystem APIs. The optional real WsgiDAV scenario publishes a
synthetic v2 and metadata through upstream PUT, reuses the same USGS-derived
bytes and uses upstream conditional range requests to fill only missing blocks.
No additional upstream code/test suite or cryptographic signature code was copied.

- `moonbitlang/x@0.5.5`: SHA-256 and platform path utilities, Apache-2.0;
  https://github.com/moonbitlang/x . Dependency source is not vendored.
- `moonbitlang/async@0.22.4`: host I/O, Apache-2.0;
  https://github.com/moonbitlang/async . Source is not vendored.
- `q2316367743/webdav@0.1.0`: the actual WebDAV client used by the integration,
  Apache-2.0; https://github.com/q2316367743/webdav . Existing download, path,
  authentication and range request APIs are composed, not copied or forked.
- `q2316367743/moonhttp@0.5.0`: upstream HTTP transport and its extension trait,
  Apache-2.0; https://github.com/q2316367743/moonhttp . The project-authored
  response guard implements that public trait and delegates wire I/O to its
  HttpConnTransport. No HTTP parser, TLS or WebDAV implementation was copied.
- `Milky2018/xml@0.5.0`: transitive WebDAV XML dependency, Apache-2.0;
  https://github.com/moonbit-community/xml-mbt . No source vendored or modified.
- `QUHONGYE-gif/modelhub`: comparison reference only, Apache-2.0;
  https://github.com/QUHONGYE-gif/moonkit-modelhub . No dependency, copied code,
  model fixtures or specialized cache integration. See docs/ecosystem.md.
- MoonBit core/scaffold: https://github.com/moonbitlang/core , Apache-2.0.
  Root LICENSE was supplied by `moon new`.
- Protocol reference: https://www.rfc-editor.org/rfc/rfc9110.html , sections
  8.8, 10.2.3, 13.1.5, 14; 429 semantics:
  https://www.rfc-editor.org/rfc/rfc6585.html#section-4 . No RFC prose or code was copied.
- Bearer header syntax/transport reference:
  https://www.rfc-editor.org/rfc/rfc6750#section-2.1 . No RFC prose/code copied;
  token validation, binding and workflow tests are project-authored Apache-2.0.
- Standard SHA-256 empty/abc test vectors:
  https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program/secure-hashing .
  Other binary test cases are project-authored deterministic data.
- USGS public-domain fixture: `fixtures/README.md` records exact source/date/hash.
- MFLARTIFACT1 schema, identity serialization/loading, pin checks and manifest
  workflow/test cases are project-authored Apache-2.0. They reuse the existing
  dependency hashing, strict UTF-8 and filesystem APIs; no third-party manifest
  format or implementation was copied. The demo reuses the USGS fixture above.
- Checkpoint candidate promotion, temporary ownership checks and recovery tests
  are project-authored Apache-2.0. The interrupted-save demo reuses the USGS fixture
  and the pinned async/filesystem APIs; no external crash-recovery code was copied.
- The WebDAV response guard, source-independent receive refactor, property and
  boundary tests, and examples/webdav loopback fixture are project-authored
  Apache-2.0. The example reuses the existing public-domain USGS snapshot. It
  implements only test PUT/GET/OPTIONS behavior, with public test credentials;
  no third-party WebDAV server or integration test code was copied.

- The shared bounded checkpoint loader and its malformed-encoding/file-boundary
  regression tests are project-authored Apache-2.0, reusing the existing strict
  UTF-8/filesystem APIs. No external validation code or test suite was copied.

- Local repair control/progress APIs, MFLREPAIR1 reports and their tests are
  project-authored Apache-2.0. The demonstration reuses the existing public-domain
  USGS fixture; no external repair-control code or test cases were copied.

- BlockReference, publisher/audit adapters and boundary/property tests are
  project-authored Apache-2.0. They reuse MFL1 and existing dependency hashing,
  strict UTF-8 and filesystem APIs. The reference example uses the existing USGS
  public-domain fixture; no external manifest code or test suite was copied.

- Reference-based checkpoint reconstruction, its sparse-mask/boundary tests and
  upstream resume comparison fixture are project-authored Apache-2.0. They call
  published client APIs and reuse the existing USGS data and MFL1 lifecycle; no
  upstream resume implementation, server or test suite was copied.

- The reference publisher/audit CLI and its actual-command preservation tests are
  project-authored Apache-2.0. They reuse the existing USGS fixture and library
  metadata/verification APIs; no external CLI implementation was copied.
- The explicit reference-adoption CLI and lost-checkpoint repair/pause/resume
  workflow are project-authored Apache-2.0, reusing that fixture and existing host
  APIs; no external recovery command or test suite was copied.

Dependencies retain copyright/license notices in their own distribution.
- `hustcer/ed25519@0.6.1`, Apache-2.0:
  https://github.com/hustcer/mbt-ed25519 and
  https://mooncakes.io/docs/hustcer/ed25519%400.6.1 . Used unmodified for plain
  Ed25519 signing/key validation/verification. The publisher policy, MFLRELEASE1
  schema, application domain, examples and tests are project-authored Apache-2.0;
  no upstream signature implementation or test cases were copied. Deterministic
  demonstration seeds are public project-authored test data. Upstream is
  unaudited and not constant-time; no stronger assurance is claimed here.
- The optional real-server integration installs unmodified WsgiDAV/Cheroot and
  their pinned dependencies in an isolated Python environment. Versions, source
  links and all primary/bundled-license qualifications are recorded in
  [integration/README.md](integration/README.md). No server code or upstream test
  suite is copied; the MoonBit harness/scenario is project-authored Apache-2.0.
`pkg.generated.mbti` files are generated by `moon info`.
