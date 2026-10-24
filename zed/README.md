# Folio Extension for Zed (`//zed/folio_zed_extension/...`)

This directory contains the **Folio WYSIWYG Markdown & $\text{LaTeX}$ Zed Extension** (`zed/folio_zed_extension`), which compiles to a standalone WASI Preview 2 component (`extension.wasm`) targeting the Zed `v0.8.0` Extension Editor API ([`lukeredmore/zed`](https://github.com/lukeredmore/zed)).

All Folio-specific Markdown & $\text{LaTeX}$ intelligence lives entirely inside `zed/folio_zed_extension` (powered by `core/folio_engine`), with zero Folio patches or dependencies inside Zed itself.

---

## 1. Download & Install `lukeredmore/zed` (with Auto-Update)

1. Download [**`Zed.dmg`**](https://github.com/lukeredmore/zed/releases/latest/download/Zed.dmg) from [`lukeredmore/zed` Releases](https://github.com/lukeredmore/zed/releases/latest).
2. Open `Zed.dmg` and drag **`Zed.app`** to `/Applications`.
3. **Original Name & Inverted Black/White Icon:** The app retains the original **`Zed.app`** name and bundle structure, and uses an **inverted black/white Zed icon** (white squircle with a black `Z` mark) so you can easily tell the modded `v0.8.0` Extension Editor API build apart from mainline Zed.
4. **Built-in App Auto-Update:** Every merge to `main` on [`lukeredmore/zed`](https://github.com/lukeredmore/zed) builds and publishes a rolling `latest` `Zed.dmg`. `Zed.app` automatically polls `lukeredmore/zed/releases/latest` (or checks manually via `zed: check for updates`) and updates itself in place.

---

## 2. Install the Folio Extension (`folio-markdown-outline`)

Install the Folio extension into `lukeredmore/zed` using any of the standard Zed extension workflows:

- **Zed Extensions UI (`Cmd-Shift-X`):**
  Open the **Extensions** tab (`Cmd-Shift-X` or `zed: extensions` in the Command Palette), find **`Folio Markdown Outline`**, and click **Install**.
- **Auto-Install in `~/.config/zed/settings.json`:**
  ```json
  {
    "auto_install_extensions": {
      "folio-markdown-outline": true
    }
  }
  ```
- **Local Source Install (Developer Workflow):**
  ```bash
  ./zed/install_extension.sh
  ```

---

## 3. Open `.md` Files in Preview View by Default

The Folio extension leaves Zed's raw Markdown source editor completely untouched and replaces the **Markdown Preview** canvas (`Cmd-Shift-V` in the active pane, or `Cmd-K V` to the side) with the interactive Folio WYSIWYG Markdown & $\text{LaTeX}$ editor.

To open all `.md` files directly in the Folio WYSIWYG preview view by default whenever you click a `.md` file in the project sidebar or fuzzy finder, set `markdown_preview.open_markdown_files_in_preview` to `true` in `~/.config/zed/settings.json`:

```json
{
  "markdown_preview": {
    "open_markdown_files_in_preview": true
  }
}
```

---

## 4. Independent Auto-Updates (`Zed.app` & Extension)

`lukeredmore/zed` (`Zed.app`) and the Folio Zed extension (`folio-markdown-outline`) are versioned, released, and auto-updated separately:

| Component | Release Artifact | Update Mechanism |
| :--- | :--- | :--- |
| **`Zed.app`** (`lukeredmore/zed`) | [`lukeredmore/zed/releases/latest/download/Zed.dmg`](https://github.com/lukeredmore/zed/releases/latest/download/Zed.dmg) | Built-in `auto_update` checks `api.github.com/repos/lukeredmore/zed/releases/latest` and installs `Zed.dmg` in place. |
| **`folio-markdown-outline`** (`lukeredmore/folio`) | [`lukeredmore/folio/releases/latest/download/folio-markdown-outline.tar.gz`](https://github.com/lukeredmore/folio/releases/latest/download/folio-markdown-outline.tar.gz) | Zed's `ExtensionStore` checks `api.github.com/repos/lukeredmore/folio/releases/latest` (`extension_version`), downloads `folio-markdown-outline.tar.gz`, and hot-reloads the extension without restarting Zed. |

---

## Upstream Zed Fork Capabilities Used (`lukeredmore/zed`)

The extension uses four general-purpose capabilities on `lukeredmore/zed`:
1. **`fix/proportional-font-monospace-code` ([`lukeredmore/zed#1`](https://github.com/lukeredmore/zed/pull/1)):** Preserves `buffer_font_family_fallback` (monospace) on code spans, fenced code blocks, and tables when `buffer_font_family` is proportional.
2. **`feat/per-language-gutter-settings` ([`lukeredmore/zed#2`](https://github.com/lukeredmore/zed/pull/2)):** Supports `languages.Markdown.gutter` overrides to hide line numbers and fold chevrons only in Markdown buffers.
3. **`feat/extension-editor-highlights` ([`lukeredmore/zed#3`](https://github.com/lukeredmore/zed/pull/3)):** `editor-highlights-for-buffer` WIT `v0.8.0` capability for cursor-aware text & full-row background highlights.
4. **`feat/extension-editor-decorations-canvas` ([`lukeredmore/zed#4`](https://github.com/lukeredmore/zed/pull/4)):** `editor-decorations-for-buffer` WIT `v0.8.0` capability for inline syntax folding (`InlineFoldDecoration`) and 2D block/inline `CanvasElement` primitives (`CanvasQuad`, `CanvasGlyphRun`, `CanvasTextReplacement`), plus extension-powered `MarkdownPreviewView`.

---

## Crate Structure

- [`zed/folio_zed_extension/`](folio_zed_extension) — Rust library crate (`folio_zed_extension`) implementing `FolioZedExtension`, `FolioZedModSession`, cursor-aware folding, $\text{LaTeX}$ math canvas layout, and Zed `v0.8.0` extension bridges.
- [`zed/folio_zed_extension/wasm/`](folio_zed_extension/wasm) — `wasm32-wasip2` `cdylib` crate linking `folio_zed_extension` with `zed_extension_api` (`v0.8.0`) and registering `register_extension!`.
- [`zed/install_extension.sh`](install_extension.sh) — Builds `extension.wasm` and installs the extension bundle locally into Zed.
- [`zed/package_extension.sh`](package_extension.sh) — Packages `folio-markdown-outline.tar.gz` for GitHub Releases distribution and automatic updates.
