# Folio for Zed (`//:zed_with_folio_mod` & `//:folio_zed_extension`)

[![Download Latest Folio-Zed.dmg](https://img.shields.io/badge/Download-Folio--Zed.dmg-0076df?style=for-the-badge&logo=apple)](https://github.com/lukeredmore/folio/releases/latest/download/Folio-Zed.dmg)

This directory contains the **Folio WYSIWYG Markdown & $\text{LaTeX}$ Editor Mod** (`zed/folio_zed_mod`) and **Built-In Companion Extension** (`zed/folio_zed_extension`) integrated into the open-source **Zed IDE** (`third_party/zed/upstream`).

---

## One-Click Download & Rolling Auto-Updates

- **Direct Download (Always Latest `main` Build):** [**Download `Folio-Zed.dmg`**](https://github.com/lukeredmore/folio/releases/latest/download/Folio-Zed.dmg)
- **Drop-In Replacement for Zed:** `Folio Zed.app` uses the same settings, keymaps, extensions, and history as vanilla `Zed.app`. It has its own single-instance port, so it opens even when vanilla Zed is running. Its icon is the Folio logo on a black Zed-style background.
- **Built-In Extension Pre-Installed:** Both release (`Folio Zed.app`) and development builds bundle `folio-markdown-outline` (`zed/folio_zed_extension`) directly inside the binary and automatically install/update it into Zed's extensions directory on launch—no manual extension installation or network download required.
- **Rolling GitHub Release Auto-Updater:**
  - Installed copies of `Folio Zed.app` check `https://api.github.com/repos/lukeredmore/folio/releases/latest` on startup (and every hour, or manually via **Zed → Check for Updates**).
  - When a newer `main` commit or build number is published to the rolling `latest` release, Zed downloads `Folio-Zed.dmg`, verifies its SHA-256 digest when present, mounts the disk image in the background, updates the `.app` bundle in place, and prompts to restart.

---

## WYSIWYG Markdown & $\text{LaTeX}$ Features in Zed

Opening any `.md` / Markdown buffer in Zed automatically transforms the editor pane into a live Folio WYSIWYG document canvas while keeping all of Zed's native IDE features (tabs, file tree, terminal, LSP, outline panel, and themes) intact:

- **Document Typography & Clean Gutter:** Uses Zed's proportional UI font with comfortable `1.65×` line spacing, soft wrapping, and clean document margins (hiding code line numbers, git diff gutter, fold chevrons, indent guides, and whitespace dots). Code fences, inline `` `code` `` pills, and active table rows automatically switch to Zed's monospace buffer font.
- **Cursor-Aware Live Folding:** Syntax markers (`#`, `**`, `*`, `~~`, `==`, `` ` ``, `[label](url)`, `$...$`, `$$...$$`) fold away on inactive lines and smoothly unfold into raw Markdown when the cursor enters that line or block.
- **Scaled Headings (`H1`–`H6`):** Inactive headings render at true scaled typographic sizes (`H1` `28px` bold + bottom rule, `H2` `22.5px` bold + bottom rule, `H3`–`H6`).
- **Fenced Code Block Cards:** Full-row surface card backgrounds (`highlight_rows`) in monospace font with Folio's colored-dot **Language Pill Header** (`RUST`, `PYTHON`, etc.).
- **Interactive Task Lists & Styled Bullets:** `- [ ]` and `- [x]` render as clickable GPUI checkboxes that toggle `[ ]` ↔ `[x]` directly in the buffer when clicked (with strikethrough on completed tasks).
- **Structured Tables & $\text{LaTeX}$ Math Cards:** Inactive pipe tables render as aligned bordered table cells with bold headers; `$...$` and `$$...$$` expressions render as native GPUI math canvases.
- **Built-In Outline & Slash Commands (`folio-markdown-outline`):** Provides enhanced Tree-sitter Markdown outline queries (`outline.scm` for headings and code fences) and `/math`, `/table`, `/callout`, and `/toc` slash command templates.

---

## Development Builds (`bazel run //:zed_with_folio_mod`)

### 1. Launch Dev Build & Restore Previous Editor Session
```bash
bazel run //:zed_with_folio_mod
```
- **Session Persistence:** Launching `bazel run //:zed_with_folio_mod` with no arguments restores your previously open workspace folder, open tabs, split panes, and cursor positions from Zed's dev state database (`0-dev`). If no previous workspace exists yet, it opens the Folio repository root on first run.
- **Dev Dock Icon:** When launched via Bazel (`bazel run //:zed_with_folio_mod`), the running dev process automatically applies the **DEV**-badged icon in the macOS Dock so you can immediately distinguish it from a release build.
- **`folio` CLI Installation:** Automatically installs the `folio` CLI wrapper to `~/.local/bin/folio` (and `/usr/local/bin/folio` if writable).

### 2. Open a Specific Folder or File in the Dev Build
Pass any folder or file path (or `--open <path>` / `--repo`) after `--`:
```bash
# Open a specific folder or file
bazel run //:zed_with_folio_mod -- ~/Notes
bazel run //:zed_with_folio_mod -- --open ~/Notes/todo.md

# Force-open the Folio monorepo root regardless of last saved session
bazel run //:zed_with_folio_mod -- --repo
```
Or use the installed `folio` CLI from any terminal:
```bash
folio                       # Restore last open workspace in Folio Zed
folio ~/Notes               # Open ~/Notes folder
folio path/to/document.md   # Open a specific Markdown file
```

---

## Building & Packaging `Folio-Zed.dmg` Locally

```bash
# Build "./Folio Zed.app" bundle at the monorepo root
./build_zed_app.sh

# Build and package "./Folio-Zed.dmg"
./scripts/package_zed_dmg.sh
```

---

## Crate Structure & Patch Workflow

- [`zed/folio_zed_mod/`](folio_zed_mod) — Rust crate bridging `folio_engine` to Zed's GPUI editor (`EditorSession`, `InlayFolding`, `MathCanvas`, `ThemeSync`).
- [`zed/folio_zed_extension/`](folio_zed_extension) — Built-in Zed extension (`extension.toml`, `languages/markdown/config.toml`, `languages/markdown/outline.scm`, and slash command providers).
- `third_party/zed/patches/0002-real-zed-editor-folio-wysiwyg.patch` — Git patch applied onto upstream Zed (`56934ec0560bce8929025497411de7f5322fb6ca`). See [`AGENTS.md`](../AGENTS.md) for worktree build and patch regeneration instructions.
