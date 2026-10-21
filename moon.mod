// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "cn-wn/moonfetchledger"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/cn-wn/moonfetchledger"

license = "Apache-2.0"

keywords = [
  "integrity",
  "audit",
  "repair",
  "recovery",
  "webdav",
  "delta",
  "update",
]

preferred_target = "native"

description = "Verified cross-version file updates, block-integrity audits and sparse recovery for existing clients."

import {
  "moonbitlang/x@0.5.5",
  "moonbitlang/async@0.22.4",
  "q2316367743/webdav@0.1.0",
  "q2316367743/moonhttp@0.5.0",
}
