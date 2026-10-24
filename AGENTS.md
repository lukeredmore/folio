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

## 2. How Moddable Zed & `libfolio_zed_mod.dylib` Work (Zero 100+ GB Local Checkout Required)

Folio decouples the **Moddable Zed** host binary (`//third_party/zed:moddable_zed_bundle`) from Folio's own crates (`core/folio_engine`, `zed/folio_zed_mod`, `zed/folio_zed_extension`):

1. **Dynamic Loading via `libfolio_zed_mod.dylib` (`//zed/folio_zed_mod:folio_zed_mod_dylib`)**:
   - Upstream Zed (`third_party/zed/upstream`) has **zero** Cargo dependencies on Folio's crates.
   - Instead, Moddable Zed dynamically loads `libfolio_zed_mod.dylib` at runtime via `dlopen`/`dlsym` (`crates/markdown/src/folio_dylib.rs`) and loads `zed/folio_zed_extension` from `Contents/Resources/builtin_extensions/` (or `FOLIO_BUILTIN_EXTENSION_DIR`).
   - Editing `core/folio_engine/**`, `zed/folio_zed_mod/**`, or `zed/folio_zed_extension/**` **never** requires compiling upstream Zed or having `third_party/zed/upstream` checked out locally.
2. **Content-Addressed Moddable Zed Bundle Cache (`~/.cache/folio/moddable-zed/<key>/`)**:
   - `third_party/zed/build_moddable_zed.sh` computes a deterministic key from the vanilla Zed release in `third_party/zed/ZED_VERSION`, the SHA-256 of `third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch`, and the build profile.
   - It resolves `moddable_zed_bundle.tar` in order:
     1. Local cache `~/.cache/folio/moddable-zed/<key>/moddable_zed_bundle.tar` (instant, 0 GB `upstream/` needed).
     2. Prebuilt GitHub Release `moddable-zed-<key>` on `lukeredmore/folio` (~170 MB `.tar.zst` download in ~2s, 0 GB `upstream/` needed).
     3. Local source build in `third_party/zed/upstream` using slim Cargo profile overrides (`~12 GB` instead of `103 GB`).

---

## 3. When You Actually Need `third_party/zed/upstream` (Only When Editing `0002-*.patch`)

If you are only editing `core/folio_engine/**`, `zed/folio_zed_mod/**`, `zed/folio_zed_extension/**`, `Sources/**`, or `Tests/**`, **skip this section** — run `cargo test --workspace`, `bazel test //...`, or `bazel run //:zed_with_folio_mod` directly without creating `third_party/zed/upstream`.

If you need to modify the host hooks in `third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch`:

### Step 1: Create an isolated `third_party/zed/upstream` worktree inside your worktree

Instead of editing `${MAIN_REPO_ROOT}/third_party/zed/upstream` or cloning Zed from GitHub, create a detached Git worktree from the existing local Zed repo:

```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
MAIN_ZED_UPSTREAM="${MAIN_REPO_ROOT}/third_party/zed/upstream"

# Create a clean checkout of the pinned vanilla Zed release inside your worktree
ZED_TAG="v$(cat "${WORKTREE_ROOT}/third_party/zed/ZED_VERSION")"
git -C "${MAIN_ZED_UPSTREAM}" fetch --depth 1 origin tag "${ZED_TAG}"
git -C "${MAIN_ZED_UPSTREAM}" worktree add --detach \
  "${WORKTREE_ROOT}/third_party/zed/upstream" "${ZED_TAG}"

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

### Updating the Pinned Zed Version

`third_party/zed/ZED_VERSION` is the only Zed pin. It must name a vanilla Zed **stable** release (for example `1.25.3` for tag `v1.25.3`), because Folio Zed downloads that release's vanilla `zed-remote-server` for SSH, WSL, and Docker remotes. Update it in its own PR:

1. Change `third_party/zed/ZED_VERSION`.
2. Rebase the patch: check out the new tag (Step 1), apply the old patch, fix conflicts, and export it (Step 3).
3. `build_moddable_zed.sh` fails if `crates/zed/Cargo.toml` in the checkout does not match `ZED_VERSION`.

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

---

## 6. Always Include Local Run Commands in Your Final Response

Whenever you finish a task in **Folio**, always include the full, copy-pasteable commands to run it locally in your final response (including the `cd` into the active worktree or repository directory), for example:
- **Standalone macOS App**:
  ```bash
  cd <worktree_or_repo_path>
  bazel run //:FolioApp
  ```
- **Moddable Zed with Folio**:
  ```bash
  cd <worktree_or_repo_path>
  bazel run //:zed_with_folio_mod
  ```


