---
name: rust-modular-refactor
description: >-
  Systematic anti-slop refactoring, module splitting, and shared behavior test enforcement
  for Folio's Rust and Swift codebase. Activate whenever splitting large files, adding new
  Rust modules, writing tests in tst/, or syncing behavior assertions across Zed and Standalone.
---

# Rust Modular Refactoring & Shared Behavior Testing Skill

## When to Activate
- Any Rust file in `core/` or `zed/` or any Swift file in `Sources/` or `Tests/` approaches or exceeds **250 lines** (hard failure at **350 lines**).
- Adding or refactoring tests (all Rust tests **must** live in `<crate>/tst/` or `tst/specs/`, never inline in `src/`; all Swift tests **must** live in focused domain-specific `*Tests.swift` files under `Tests/FolioTests/`, never in a monolithic `FolioTests.swift`).
- Implementing or modifying markdown parsing, active-line folding, keystroke editing, math layout, or paragraph reflow shared between Zed and Standalone Folio.

---

## 1. Anti-Monolith Rules (Hard Guardrails)
1. **Max File Length**:
   - Target **<= 250 lines** per `.rs` or `.swift` file.
   - Hard ceiling: **350 lines** (enforced by `./scripts/audit_slop.sh`).
2. **Zero Inline Tests in `src/` & No Monolithic Test Files**:
   - Never place `#[cfg(test)]` or `#[test]` inside `src/**.rs`.
   - Place Rust crate tests in `<crate>/tst/*.rs` and wire them via `[[test]]` in `Cargo.toml` and `rust_test` in `BUILD.bazel`.
   - Place Swift tests in focused domain-specific `*Tests.swift` files (`<= 350` lines each) under `Tests/FolioTests/`.
3. **No Linter Tampering**:
   - `allow_attributes = "deny"` is enforced in workspace Clippy lints. Do not silence `clippy::too_many_lines` or `clippy::cognitive_complexity` with `#[allow(...)]`; split the function or module instead.
4. **Minimal Zed Patch Surface**:
   - Never embed standalone algorithms, string/cursor manipulation helpers, or unit tests directly inside `third_party/zed/patches/*.patch`.
   - Implement pure logic in `core/folio_engine` or `zed/folio_zed_mod`, test it in `tst/`, and keep the Zed patch to thin delegation glue.

---

## 2. The Strangler Pattern for Splitting Large Rust Files
When splitting a monolithic module `foo.rs` into a directory module `foo/`:
1. **Create Submodule Directory**: Create `src/foo/mod.rs` and move types/functions one logical domain at a time into leaf files (`src/foo/types.rs`, `src/foo/scanner.rs`, etc.).
2. **Preserve Public API Surface**: Re-export public items in `src/foo/mod.rs` (or `src/lib.rs`) using `pub use` so external callers and FFI bridges do not break during extraction.
3. **Sync Build Systems Immediately**: Whenever adding or renaming `.rs` files, update **both** `Cargo.toml` (if adding `[[test]]` targets) and `BUILD.bazel` (`ENGINE_SRCS` / `rust_library` / `rust_test`).
4. **Incremental Verification**: Run `./scripts/audit_slop.sh` and `bazel test //core/... //zed/...` after each extraction step.

---

## 3. Shared Behavior-Asserting Tests (`tst/specs/`)
Whenever adding or fixing markdown live styling, active-line reveal/collapse, list continuation, inline delimiter toggling, heading toggling, or reflow:
1. Add a declarative cursor-marked test case (using `|` for cursor or `[...]` for selection) in `tst/specs/*.json`.
2. Verify that **both** `core/folio_engine/tst/behavior_suite.rs`, `zed/folio_zed_mod/tst/behavior_suite.rs`, and Swift `Tests/FolioTests/BehaviorSpecTests.swift` pass against the shared spec definition.
