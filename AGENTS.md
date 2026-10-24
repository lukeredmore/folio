# AGENTS.md — Folio Monorepo Agent & Worktree Guide

This document provides critical architecture and workflow instructions for AI coding agents working in the **Folio** monorepo, particularly when operating inside isolated Git worktrees (e.g. `~/.gemini/antigravity/worktrees/Folio/<worktree_name>`).

---

## 1. Golden Rule: Never Mutate the Main Checkout When Working in a Worktree

If your workspace is a Git worktree rather than the primary checkout, **all file edits and test runs must stay strictly inside your worktree**.

You can dynamically resolve the primary checkout root from any worktree via Git:
```bash
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
```

Do **not** modify files in `${MAIN_REPO_ROOT}` (`main`) or copy uncommitted changes back into `main` unless the user explicitly asks you to merge or sync them.

---

## 2. Zed Extension Architecture (`zed/folio_zed_extension`)

Folio integrates with Zed as a standalone WASI Preview 2 extension (`zed/folio_zed_extension`) targeting the Zed `v0.8.0` Extension Editor API (`lukeredmore/zed`), with zero Folio patches or dependencies inside Zed:

- **Host library & test suite (`zed/folio_zed_extension`)**:
  - Workspace member crate tested via `cargo test --workspace` and `bazel test //zed/folio_zed_extension/...`.
  - Contains `FolioZedExtension`, `FolioZedModSession`, cursor-aware syntax folding, $\text{LaTeX}$ math canvas primitives, and `v0.8.0` `EditorHighlights` / `EditorDecorations` builders.
- **WASI Preview 2 component (`zed/folio_zed_extension/wasm`)**:
  - Built and installed into Zed via `./zed/install_extension.sh`.

---

## 3. Building & Testing in a Worktree

All targets in the monorepo (`//core/folio_engine/...`, `//:FolioApp`, `//:FolioTests`, `//zed/folio_zed_extension/...`) are self-contained and build directly inside any worktree via Bazel or Cargo:

- **Bazel builds & tests** (always run with your worktree as `Cwd`):
  ```bash
  bazel test //...
  bazel build //:FolioApp
  ```
- **Rust core & extension unit tests**:
  ```bash
  cargo test --workspace
  ```
- **Build & install the Zed WASI extension**:
  ```bash
  ./zed/install_extension.sh
  ```

---

## 4. Anti-Slop Module Hygiene, File Size Limits & `tst/` Testing Rules

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

## 5. Always Include Local Run Commands in Your Final Response

Whenever you finish a task in **Folio**, always include the full, copy-pasteable commands to run it locally in your final response (including the `cd` into the active worktree or repository directory), for example:
- **Standalone macOS App**:
  ```bash
  cd <worktree_or_repo_path>
  bazel run //:FolioApp
  ```
- **Zed WASI Extension**:
  ```bash
  cd <worktree_or_repo_path>
  ./zed/install_extension.sh
  ```

