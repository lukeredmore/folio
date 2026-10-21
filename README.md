# Folio

**Folio** is a live hybrid WYSIWYG Markdown & $\text{LaTeX}$ editing suite built on a shared Rust layout engine.

## Products & Downloads

- **Folio for macOS (`Folio.app`)** — Standalone native macOS Markdown & $\text{LaTeX}$ notebook (`AppKit` + `TextKit` + `SwiftUI`) with live inline syntax folding, custom themes, and automatic rolling updates. [**Download `Folio.dmg`**](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg) · [macOS Docs](macos/README.md)
- **Folio Zed (`Folio Zed.app`)** — Custom build of the open-source Zed IDE with Folio's WYSIWYG Markdown & $\text{LaTeX}$ editor mod (`folio_zed_mod`) and the `folio-markdown-outline` extension bundled out of the box, plus automatic rolling updates. [**Download `Folio-Zed.dmg`**](https://github.com/lukeredmore/folio/releases/latest/download/Folio-Zed.dmg) · [Zed Docs](zed/README.md)

---

## Quick Start & Common Commands

Requires `bazel` / `bazelisk` (`brew install bazelisk`):

```bash
# Run the standalone macOS app
bazel run //:FolioApp

# Run the Folio-modded Zed IDE (restores previous workspace, or open a specific path)
bazel run //:zed_with_folio_mod
bazel run //:zed_with_folio_mod -- /path/to/folder

# Run all unit, integration, and shared behavior tests
bazel test //...

# Package release .dmg installers locally
./scripts/package_dmg.sh       # Produces ./Folio.dmg
./scripts/package_zed_dmg.sh   # Produces ./Folio-Zed.dmg
```

---

## Repository Overview

| Package | Targets | Documentation |
| :--- | :--- | :--- |
| **`core/folio_engine`** | `//core/folio_engine`, `//core/folio_engine:folio_engine_ffi` | [Core Engine README](core/folio_engine/README.md) — Shared Rust Markdown AST/span scanner, active-line token folding, native $\text{LaTeX}$ box layout, paragraph reflow, and C-ABI FFI. |
| **`macos/` & `Sources/Folio/`** | `//:FolioApp`, `//:FolioTests` | [macOS App README](macos/README.md) — Standalone macOS app features, keyboard shortcuts, typography themes, `.dmg` packaging, and GitHub Release auto-updates. |
| **`zed/` & `third_party/zed/`** | `//:zed_with_folio_mod`, `//:folio_zed_extension` | [Zed Mod & Extension README](zed/README.md) — GPUI WYSIWYG editor integration, built-in extension bundle, `folio` CLI, dev workspace persistence, and `Folio-Zed.dmg` builds. |
