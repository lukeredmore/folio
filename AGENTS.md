# AGENTS.md — Folio Monorepo Agent & Worktree Guide

This document provides critical architecture and workflow instructions for AI coding agents working in the **Folio** monorepo, particularly when operating inside isolated Git worktrees (e.g. `~/.gemini/antigravity/worktrees/Folio/<worktree_name>`).

---

## 1. Golden Rule: Never Mutate the Main Checkout When Working in a Worktree

If your workspace is a Git worktree rather than the primary checkout, **all file edits, patch updates, and test runs must stay strictly inside your worktree**.

You can dynamically resolve the primary checkout root from any worktree via Git:
```bash
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
```

Do **not** modify files in `${MAIN_REPO_ROOT}` (`main`) or copy uncommitted changes back into `main` unless the user explicitly asks you to merge or sync them.

---

## 2. Why `third_party/zed/upstream` Requires Special Handling in Worktrees

Folio builds a custom-patched version of the Zed IDE (`//:zed_with_folio_mod`). Understanding how Zed is structured in this repo avoids accidentally dirtying `main` or triggering a 68 GB rebuild:

1. **`third_party/zed/upstream/` is Git-ignored**:
   - The full upstream Zed repository (`zed-industries/zed` at commit `56934ec0560bce8929025497411de7f5322fb6ca`) lives at `${MAIN_REPO_ROOT}/third_party/zed/upstream`.
   - Because it is listed in `.gitignore`, creating a new Folio worktree does **not** automatically populate `<worktree>/third_party/zed/upstream`.
2. **The Cargo `target/` directory is ~68 GB**:
   - `${MAIN_REPO_ROOT}/third_party/zed/upstream/target` holds ~68 GB of incremental Rust build artifacts.
   - Cloning and compiling Zed from scratch without sharing this cache takes 30+ minutes and 68 GB of disk space.
3. **Relative path dependencies in `upstream/Cargo.toml`**:
   - The patched `third_party/zed/upstream/Cargo.toml` references Folio's workspace crates using relative paths:
     ```toml
     folio_engine = { path = "../../../core/folio_engine" }
     folio_zed_mod = { path = "../../../zed/folio_zed_mod" }
     ```
   - If you run `cargo build` inside `${MAIN_REPO_ROOT}/third_party/zed/upstream`, those `../../../` paths resolve to `${MAIN_REPO_ROOT}` (`main`), **ignoring your worktree's `core/folio_engine` and `zed/folio_zed_mod` changes** and tempting agents to edit `main` directly.

---

## 3. How to Build & Test Zed Inside Your Own Worktree (Isolated Source + Shared Cache)

When working on Zed (`third_party/zed/**`, `zed/folio_zed_mod/**`, `zed/folio_zed_extension/**`, or `core/folio_engine/**`) inside a Folio worktree, set up a lightweight Git worktree for `upstream` inside your Folio worktree and share the `CARGO_TARGET_DIR` cache.

*(Note: Running `bazel run //:zed_with_folio_mod` or `./third_party/zed/run_zed_with_folio_mod.sh` inside a worktree will perform Steps 1 & 2 automatically.)*

### Step 1: Create an isolated `third_party/zed/upstream` worktree inside your worktree

Instead of editing `${MAIN_REPO_ROOT}/third_party/zed/upstream` or cloning Zed from GitHub, create a detached Git worktree from the existing local Zed repo:

```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
MAIN_ZED_UPSTREAM="${MAIN_REPO_ROOT}/third_party/zed/upstream"

# Create a clean checkout of the base Zed commit inside your worktree
git -C "${MAIN_ZED_UPSTREAM}" worktree add --detach \
  "${WORKTREE_ROOT}/third_party/zed/upstream" \
  56934ec0560bce8929025497411de7f5322fb6ca

# Apply your worktree's Folio patch
git -C "${WORKTREE_ROOT}/third_party/zed/upstream" apply \
  "${WORKTREE_ROOT}/third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch"
```

Because `${WORKTREE_ROOT}/third_party/zed/upstream` sits inside your worktree, its `../../../core/folio_engine` and `../../../zed/folio_zed_mod` dependencies in `Cargo.toml` will automatically resolve to **your worktree's crates**, not `main`.

### Step 2: Share `CARGO_TARGET_DIR` (or symlink `target/`) to reuse the 68 GB build cache

To avoid recompiling all of Zed from scratch while compiling in your worktree:

```bash
ln -s "${MAIN_ZED_UPSTREAM}/target" "${WORKTREE_ROOT}/third_party/zed/upstream/target"
```
*(Or export `CARGO_TARGET_DIR="${MAIN_ZED_UPSTREAM}/target"`.)*

Then run targeted Cargo tests or builds from your worktree's `upstream` directory:

```bash
cd "${WORKTREE_ROOT}/third_party/zed/upstream"
cargo test -p markdown
cargo build -p zed
```

### Step 3: Export updated patches back to your worktree (NOT `main`)

Whenever you modify files inside `${WORKTREE_ROOT}/third_party/zed/upstream`, regenerate the patch file inside **your worktree**:

```bash
git -C "${WORKTREE_ROOT}/third_party/zed/upstream" diff > \
  "${WORKTREE_ROOT}/third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch"
```

### Step 4: Clean up the nested `upstream` worktree when finished

Before removing your Folio worktree, prune or remove the nested `third_party/zed/upstream` worktree so `${MAIN_ZED_UPSTREAM}` stays clean:

```bash
git -C "${MAIN_ZED_UPSTREAM}" worktree remove --force \
  "${WORKTREE_ROOT}/third_party/zed/upstream"
```

---

## 4. Building & Testing Non-Zed Targets in a Worktree

All other targets in the monorepo (`//core/folio_engine/...`, `//:FolioApp`, `//:FolioTests`, `//zed/folio_zed_mod/...`, `//zed/folio_zed_extension/...`) are self-contained and build directly inside any worktree via Bazel or Cargo without extra setup:

- **Bazel builds & tests** (always run with your worktree as `Cwd`):
  ```bash
  bazel test //...
  bazel build //:FolioApp
  ```
- **Rust core & mod unit tests**:
  ```bash
  cargo test --workspace
  ```

---

## 5. Anti-Slop Module Hygiene, File Size Limits & `tst/` Testing Rules

To prevent monolithic files and duplicated test logic across Zed and Standalone Folio, all contributions must pass `./scripts/audit_slop.sh`:

1. **Strict File Size Ceiling (`<= 250` lines target, `350` lines hard max)**:
   - Every `.rs` file in `core/` and `zed/` and every `.swift` file in `Sources/` and `Tests/` must remain under **350 lines** (warnings trigger at **250 lines**).
   - If a file approaches 300 lines, split it into focused submodules (`mod.rs` + single-responsibility leaf modules in Rust, or `Type+Feature.swift` / domain-specific files in Swift) before adding new features.
2. **Zero Inline Tests in `src/` & Domain-Split Test Files**:
   - **Never** add `#[cfg(test)]` or `#[test]` inside `src/**.rs`.
   - Every Rust crate (`core/folio_engine`, `zed/folio_zed_mod`, `zed/folio_zed_extension`) keeps its tests strictly under `<crate>/tst/*.rs`, registered via `[[test]]` in `Cargo.toml` and `rust_test` in `BUILD.bazel`.
   - Swift tests in `Tests/FolioTests/` are split by domain (`*Tests.swift` + `FolioTestHelpers.swift`); never reintroduce a monolithic `Tests/FolioTests/FolioTests.swift`.
3. **Shared Declarative Behavior Specs (`tst/specs/*.json`)**:
   - Product behaviors shared between Zed and Standalone Folio (active-line syntax reveal vs. inactive-line folding, block decorations, newline list/task continuation, inline delimiter toggling, heading toggling, and paragraph reflow) are defined in cursor-annotated JSON specs under `tst/specs/` and executed against `folio_engine`, `folio_zed_mod`, and `FolioTests`.
4. **No Linter Tampering**:
   - Workspace Clippy lints enforce `allow_attributes = "deny"`, `too_many_lines = "warn"`, and `cognitive_complexity = "warn"` (configured in `clippy.toml`). Never silence warnings with `#[allow(...)]`; refactor the function or module instead.

