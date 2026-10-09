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

keywords = [ "download", "range", "recovery", "storage", "ledger" ]

preferred_target = "native"

description = "Sparse HTTP download reception and verified storage recovery ledger."

import {
  "moonbitlang/x@0.5.5",
  "moonbitlang/async@0.21.3",
}
