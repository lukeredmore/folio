---
name: rust-modular-refactor
description: >-
  Systematic anti-slop refactoring, module splitting, and shared behavior test enforcement
  for Folio's Rust and Swift codebase. Activate when splitting a module by responsibility, adding
  Rust modules, writing tests in tst/, or syncing behavior assertions across Zed and Standalone.
---

# Rust Modular Refactoring & Shared Behavior Testing Skill

## When to Activate
- A module or type has more than one responsibility and needs to be split.
- Adding or refactoring tests. Rust tests live in `<crate>/tst/*.rs` or `tst/specs/`, never inline in `src/`. Swift tests live in focused `Tests/FolioTests/*Tests.swift` files grouped by behavior.
- Changing markdown parsing, active-line folding, keystroke editing, math layout, or paragraph reflow shared between Zed and Standalone Folio.

---

## 1. Guardrails
1. **Split by responsibility, not by line count.** Do not split a type into extension files, or pack several statements onto one line, only to make a file shorter.
2. **No inline tests in `src/`.** Bazel creates one `rust_test` per `<crate>/tst/*.rs` file automatically; Cargo still needs a `[[test]]` entry for rust-analyzer.
3. **No lint suppression.** `allow_attributes` is denied. Split the function or module instead of adding `#[allow(...)]`.
4. **Never weaken a check to get green.** See `AGENTS.md` section 3.

---

## 2. The Strangler Pattern for Splitting Large Rust Files
When splitting a module `foo.rs` into a directory module `foo/`:
1. **Create the submodule directory.** Create `src/foo/mod.rs` and move types and functions one logical domain at a time into leaf files (`src/foo/types.rs`, `src/foo/scanner.rs`, etc.).
2. **Preserve the public API.** Re-export public items in `src/foo/mod.rs` (or `src/lib.rs`) with explicit `pub use` items so callers and FFI bridges do not break.
3. **Verify after each step.** Run `bazel test //core/... //zed/...`. Bazel globs `src/**/*.rs`, so new files need no BUILD edits.

---

## 3. Shared Behavior-Asserting Tests (`tst/specs/`)
When adding or fixing active-line reveal/collapse, list continuation, inline delimiter toggling, heading toggling, or task checkboxes:
1. Add a cursor-marked case (`|` for cursor) to `tst/specs/editor_behaviors.json`.
2. Run `bazel test //...`. `core/folio_engine/tst/behavior_suite.rs`, `zed/folio_zed_extension/tst/behavior_suite.rs`, and `Tests/FolioTests/BehaviorSpecTests.swift` all run the spec.
3. Known gap: these runners call engine functions, not each product's real edit path. A passing spec does not yet prove that the app or Zed behaves the same way.
