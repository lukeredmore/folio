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

## 2. The Only Gate: `bazel test //...`

Run this from your worktree before you report any task as done:

```bash
bazel test //...
```

It builds every target and runs every test, clippy (as a Bazel aspect, with the lints from `Cargo.toml` and `clippy.toml`), `rustfmt` checks, and `swift-format` checks (`//:swift_format`, with `.swift-format`). First-party Swift compiles with `-warnings-as-errors`. It also builds the shipped Zed `extension.wasm`. Bazel caches results, so unchanged targets cost nothing. A task is not done until this command passes.

To fix formatting:

```bash
bazel run @rules_rust//:rustfmt -- //core/... //zed/...
git ls-files '*.swift' | xargs xcrun swift-format format --in-place --parallel --configuration .swift-format
bazel run //tools:buildifier
```

Other commands:

```bash
bazel build //:FolioApp
bazel run //:FolioApp -- path/to/file.md:10:1
bazel run //:folio -- path/to/file.md:10:1
bazel run //:install_zed_extension
bazel build --config=release //:FolioDmg //:folio_zed_extension
bazel run //tools:setup_sourcekit_bsp  # Swift indexing for sourcekit-lsp; see README.md
```

Both `bazel run` launchers accept the full `folio` CLI interface (`[path[:line[:column]] ...]`, directories, `.`, `~`, `file://`, `--help`, `--version`) and resolve relative paths against your shell's working directory (`BUILD_WORKING_DIRECTORY`).

Builds without `--config=release` are dev builds. They run as **Folio Dev** with bundle ID `app.folio.macos.dev`, so they have their own preferences (`~/Library/Preferences/app.folio.macos.dev.plist`), CLI queue, caches, and SSH sockets. They do not signal or update the installed `Folio.app`, do not install the `folio` command, and are never the default app for a file type.

For screenshots and manual checks:

1. Use a dev build. Never launch `/Applications/Folio.app`.
2. Open a copy of the project (for example `cp -R examples /tmp/folio-check`), never the user's original files.
3. Never send clicks or keystrokes to any window. Open files with `path:line:column` CLI arguments and capture the window with `screencapture -l <window-id>`.
4. Quit the dev build when the capture is done. Its window takes keyboard focus when it opens.

Cargo still works for editor tooling (rust-analyzer), but it is not a gate. Bazel is the source of truth for builds, lints, and tests.

---

## 3. Code and Test Rules

1. **Never weaken a check to get green.** Do not loosen a threshold, skip a test, widen a tolerance, or edit a baseline to make a failure pass. If a check fails, fix the cause or stop and report the failure.
2. **No lint suppression.** `allow_attributes` is denied. Never add `#[allow(...)]`; refactor instead.
3. **Tests live outside `src/`.** Rust tests go in `<crate>/tst/*.rs`; Bazel creates one `rust_test` per file automatically. Swift tests go in focused `Tests/FolioTests/*Tests.swift` files, grouped by behavior.
4. **Split files by responsibility, not by line count.** Do not split a type into extension files, or pack statements onto one line, only to make a file shorter.
5. **Shared behavior specs.** `tst/specs/editor_behaviors.json` holds cursor-annotated cases for newline list and task continuation, inline delimiter toggling, heading levels, task checkboxes, and active-line fold/reveal. The engine, the Zed extension, and `FolioTests` each run them. Known gap: the runners call engine functions, not each product's real edit path, so a passing spec does not yet prove the app or Zed behaves the same way.

---

## 4. Final Responses

State that `bazel test //...` passed in your worktree. If you did not run it, or it failed, say so plainly.

Whenever you finish a task in **Folio** that results in a material change to one or more elements/applications (i.e. Zed extension, standalone app, CLI, Zed fork, etc.), always include at least one copy-pasteable command to demonstrate it. If rendered content may be affected, ensure your command opens an example file that is filled with relevant content.

For changes affecting the standalone macOS app or CLI, prefer launching the worktree build directly via Bazel with CLI arguments pointing to the relevant file (and optional `:line[:column]`):
```bash
bazel run //:FolioApp -- path/to/example.md:1:1
```
