# Code and Test Rules

`AGENTS.md` sections 2 and 3 are the source of truth. In short:

1. **Gate:** run `bazel test //...` before you report any Rust or Swift task as done. It runs all tests, clippy, and rustfmt checks, and builds the Zed `extension.wasm`.
2. **Never weaken a check to get green:** no loosened thresholds, skipped tests, widened tolerances, or edited baselines.
3. **No `#[allow(...)]`:** refactor instead.
4. **Tests outside `src/`:** Rust tests in `<crate>/tst/*.rs`; Swift tests in focused `Tests/FolioTests/*Tests.swift` files.
5. **Split by responsibility, not line count.**
