# AGENTS.md — Folio Monorepo Agent & Worktree Guide

This document provides critical architecture and workflow instructions for AI coding agents working in the **Folio** monorepo, particularly when operating inside isolated Git worktrees

---

## 1. Golden Rule: Never Mutate the Main Checkout When Working in a Worktree

If your workspace is a Git worktree rather than the primary checkout, **all file edits and test runs must stay strictly inside your worktree**.

You can dynamically resolve the primary checkout root from any worktree via Git:
```bash
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
```

Do **not** modify files in `${MAIN_REPO_ROOT}` (`main`) or copy uncommitted changes back into `main` unless the user explicitly asks you to merge or sync them.

---

## 2. Building & Testing in a Worktree

All targets in the monorepo are self-contained and build directly inside any worktree via Bazel or Cargo:

- **Bazel builds, tests & CLI launches** (always run with your worktree as `Cwd`):
  ```bash
  bazel test //...
  bazel build //:FolioApp
  bazel run //:FolioApp -- path/to/file.md:10:1
  bazel run //:folio -- path/to/file.md:10:1
  ```
  Both `bazel run //:FolioApp -- <args>` and `bazel run //:folio -- <args>` accept the full `folio` CLI interface (`[path[:line[:column]] ...]`, directories, `.`, `~`, `file://`, `--help`, `--version`) and resolve relative paths against your shell's working directory (`BUILD_WORKING_DIRECTORY`).
- **Rust core & extension unit tests**:
  ```bash
  cargo test --workspace
  ```
- **Build & install the Zed WASI extension**:
  ```bash
  ./zed/install_extension.sh
  ```

---

## 3. Anti-Slop Module Hygiene, File Size Limits & `tst/` Testing Rules

To prevent monolithic files and duplicated test logic across the Zed extension and Standalone Folio, all contributions must pass `./scripts/audit_slop.sh`:

1. **Strict File Size Ceiling (`<= 250` lines target, `350` lines hard max)**:
   - Every `.rs` file in `core/` and `zed/` and every `.swift` file in `Sources/` and `Tests/` must remain under **350 lines** (warnings trigger at **250 lines**).
   - If a file approaches 300 lines, split it into focused submodules (`mod.rs` + single-responsibility leaf modules in Rust, or `Type+Feature.swift` / domain-specific files in Swift) before adding new features.
2. **Zero Inline Tests in `src/` & Domain-Split Test Files**:
   - **Never** add `#[cfg(test)]` or `#[test]` inside `src/**.rs`.
   - Every Rust crate (`core/folio_engine`, `zed/folio_zed_extension`) keeps its tests strictly under `<crate>/tst/*.rs`, registered via `[[test]]` in `Cargo.toml` and `rust_test` in `BUILD.bazel`.
   - Swift tests in `Tests/FolioTests/` are split by domain (`*Tests.swift` + `FolioTestHelpers.swift`); never reintroduce a monolithic `Tests/FolioTests/FolioTests.swift`.
3. **Shared Declarative Behavior Specs (`tst/specs/*.json`)**:
   - Product behaviors shared between the Zed extension and Standalone Folio (active-line syntax reveal vs. inactive-line folding, block decorations, newline list/task continuation, inline delimiter toggling, heading toggling, and paragraph reflow) are defined in cursor-annotated JSON specs under `tst/specs/` and executed against `folio_engine`, `folio_zed_extension`, and `FolioTests`.
4. **No Linter Tampering**:
   - Workspace Clippy lints enforce `allow_attributes = "deny"`, `too_many_lines = "warn"`, and `cognitive_complexity = "warn"` (configured in `clippy.toml`). Never silence warnings with `#[allow(...)]`; refactor the function or module instead.

---

## 4. Final Responses

Whenever you finish a task in **Folio** that results in a material change to one or more elements/applications (i.e. Zed extension, standalone app, CLI, Zed fork, etc.), always include at least one copy-pasteable command to demonstrate it. If rendered content may be affected, ensure your command opens an example file that is filled with relevant content.

For changes affecting the standalone macOS app or CLI, prefer launching the worktree build directly via Bazel with CLI arguments pointing to the relevant file (and optional `:line[:column]`):
```bash
bazel run //:FolioApp -- path/to/example.md:1:1
```
