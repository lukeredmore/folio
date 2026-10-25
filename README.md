# Folio

**Folio** is a live hybrid WYSIWYG Markdown & $\text{LaTeX}$ editing suite built on a shared Rust layout engine (`folio_engine`).

## Products & Downloads

- **Folio for macOS (`Folio.app`)** — Standalone native macOS Markdown & $\text{LaTeX}$ notebook (`AppKit` + `TextKit` + `SwiftUI`) with live inline syntax folding, custom themes, and automatic rolling updates. [**Download `Folio.dmg`**](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg) · [macOS Docs](macos/README.md)
- **Folio Extension for Zed (`folio-markdown-outline`)** — Standalone WASI Preview 2 Zed extension (`extension.wasm`) that replaces Zed's Markdown Preview canvas with the interactive Folio WYSIWYG Markdown & $\text{LaTeX}$ editor on top of [`lukeredmore/zed`](https://github.com/lukeredmore/zed) (the Zed fork with the `v0.8.0` Extension Editor API). [**Download `Zed.dmg` (`lukeredmore/zed`)**](https://github.com/lukeredmore/zed/releases/latest/download/Zed.dmg) · [**Download `folio-markdown-outline.tar.gz`**](https://github.com/lukeredmore/folio/releases/latest/download/folio-markdown-outline.tar.gz) · [Zed Extension Docs](zed/README.md)

---

## Using Folio in Zed

### 1. Download & Install `lukeredmore/zed` (with Auto-Update)

Download [**`Zed.dmg`**](https://github.com/lukeredmore/zed/releases/latest/download/Zed.dmg) from [`lukeredmore/zed` Releases](https://github.com/lukeredmore/zed/releases/latest) and drag **`Zed.app`** to `/Applications`:

- **Original Name & Inverted Icon:** The app keeps the original **`Zed.app`** name and uses an **inverted black/white Zed icon** (white squircle background with a black `Z` emblem) so you can immediately distinguish the `v0.8.0` Extension Editor API build from upstream Zed in the Dock and Command-Tab switcher.
- **Automatic App Updates:** Every merge to `main` on [`lukeredmore/zed`](https://github.com/lukeredmore/zed) automatically builds and publishes a rolling `latest` `Zed.dmg` via GitHub Actions. `Zed.app` checks `lukeredmore/zed/releases/latest` in the background (or on demand via `zed: check for updates` in the Command Palette) and updates itself in place.

### 2. Install the Folio Zed Extension (`folio-markdown-outline`)

You can install the Folio extension into `lukeredmore/zed` the same way as any Zed extension:

- **Option A — Zed Extensions UI (Recommended):**
  Open Zed, press **`Cmd-Shift-X`** (or run `zed: extensions` from the Command Palette), search for **`Folio Markdown Outline`**, and click **Install**.
- **Option B — Auto-Install via `~/.config/zed/settings.json`:**
  Add `folio-markdown-outline` to `auto_install_extensions` in your Zed settings:
  ```json
  {
    "auto_install_extensions": {
      "folio-markdown-outline": true
    }
  }
  ```
- **Option C — Build & Install Locally from Source:**
  ```bash
  ./zed/install_extension.sh
  ```

### 3. Open `.md` Files in the WYSIWYG Preview View by Default

When the Folio extension is installed, Zed's raw Markdown source editor stays untouched while **Markdown Preview** (`Cmd-Shift-V` in the active pane, or `Cmd-K V` to the side) renders the live Folio WYSIWYG Markdown & $\text{LaTeX}$ editor.

To automatically open `.md` files directly in the Folio WYSIWYG preview view by default, add this to `~/.config/zed/settings.json`:

```json
{
  "markdown_preview": {
    "open_markdown_files_in_preview": true
  }
}
```

### 4. Independent Auto-Updates (`Zed.app` vs. Folio Extension)

`lukeredmore/zed` and the Folio Zed extension release and auto-update **independently**:
- **`Zed.app` (`lukeredmore/zed`):** Updates from [`lukeredmore/zed/releases/latest`](https://github.com/lukeredmore/zed/releases/latest) (`Zed.dmg`) whenever the Zed fork merges to `main`.
- **Folio Extension (`folio-markdown-outline`):** Every merge to `main` in [`lukeredmore/folio`](https://github.com/lukeredmore/folio) builds and publishes [`folio-markdown-outline.tar.gz`](https://github.com/lukeredmore/folio/releases/latest/download/folio-markdown-outline.tar.gz) to `lukeredmore/folio/releases/latest`. Zed's extension host automatically checks `lukeredmore/folio/releases/latest` and hot-reloads new versions of `folio-markdown-outline` without needing to update or restart `Zed.app`.

---

## Quick Start & Common Commands

Requires `bazel` / `bazelisk` (`brew install bazelisk`):

```bash
# Run the standalone macOS app (accepts any `folio` CLI arguments: files, folders, :line:col, --help, --version)
bazel run //:FolioApp -- README.md:20:1

# Or invoke the bundled `folio` CLI launcher directly via Bazel
bazel run //:folio -- README.md:20:1

# Build and install the Folio WASI extension into Zed
./zed/install_extension.sh

# Package the Folio WASI extension archive (folio-markdown-outline.tar.gz)
./zed/package_extension.sh

# Run all unit, integration, and shared behavior tests
bazel test //...
cargo test --workspace

# Package standalone macOS Folio.dmg locally
./scripts/package_dmg.sh       # Produces ./Folio.dmg
```

---

## Repository Overview

| Package | Targets | Documentation |
| :--- | :--- | :--- |
| **`core/folio_engine`** | `//core/folio_engine`, `//core/folio_engine:folio_engine_ffi` | [Core Engine README](core/folio_engine/README.md) — Shared Rust Markdown AST/span scanner, active-line token folding, native $\text{LaTeX}$ box layout, paragraph reflow, and C-ABI FFI. |
| **`macos/` & `Sources/Folio/`** | `//:FolioApp`, `//:folio`, `//:FolioTests` | [macOS App README](macos/README.md) — Standalone macOS app features, bundled `folio` CLI (`Contents/Resources/bin/folio`), keyboard shortcuts, typography themes, `.dmg` packaging, and GitHub Release auto-updates. |
| **`zed/folio_zed_extension/`** | `//zed/folio_zed_extension/...` | [Zed Extension README](zed/README.md) — Standalone WASI Preview 2 Zed extension (`v0.8.0` Extension Editor API), installation, independent auto-updates, and default preview view settings. |
