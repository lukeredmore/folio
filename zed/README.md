# Folio Extension for Zed (`//:folio_zed_extension`)

This directory contains the **Folio WYSIWYG Markdown & $\text{LaTeX}$ Zed Extension** (`zed/folio_zed_extension`), which compiles to a standalone WASI Preview 2 component (`extension.wasm`) targeting the Zed `v0.8.0` Extension Editor API (`lukeredmore/zed`).

All Folio-specific Markdown & $\text{LaTeX}$ intelligence lives entirely inside `zed/folio_zed_extension` (powered by `core/folio_engine`), with zero Folio patches or dependencies inside Zed itself.

---

## Installing into Your Zed Fork

Build the `wasm32-wasip2` extension component and install it directly into Zed's `extensions/installed/folio-markdown-outline` directory:

```bash
./zed/install_extension.sh
```

The raw Markdown source editor (`crates/editor`) remains completely untouched. To open the interactive **Folio WYSIWYG Markdown & $\text{LaTeX}$ Editor**, open any `.md` file in Zed and open **Markdown Preview** (`Cmd-Shift-V` in the active pane, or `Cmd-K V` to the side).

---

## Upstream Zed Fork Capabilities Used (`lukeredmore/zed`)

The extension uses four general-purpose capabilities on `lukeredmore/zed`:
1. **`fix/proportional-font-monospace-code` ([`lukeredmore/zed#1`](https://github.com/lukeredmore/zed/pull/1)):** Preserves `buffer_font_family_fallback` (monospace) on code spans, fenced code blocks, and tables when `buffer_font_family` is proportional.
2. **`feat/per-language-gutter-settings` ([`lukeredmore/zed#2`](https://github.com/lukeredmore/zed/pull/2)):** Supports `languages.Markdown.gutter` overrides to hide line numbers and fold chevrons only in Markdown buffers.
3. **`feat/extension-editor-highlights` ([`lukeredmore/zed#3`](https://github.com/lukeredmore/zed/pull/3)):** `editor-highlights-for-buffer` WIT `v0.8.0` capability for cursor-aware text & full-row background highlights.
4. **`feat/extension-editor-decorations-canvas` ([`lukeredmore/zed#4`](https://github.com/lukeredmore/zed/pull/4)):** `editor-decorations-for-buffer` WIT `v0.8.0` capability for inline syntax folding (`InlineFoldDecoration`) and 2D block/inline `CanvasElement` primitives (`CanvasQuad`, `CanvasGlyphRun`, `CanvasTextReplacement`).

---

## Crate Structure

- [`zed/folio_zed_extension/`](folio_zed_extension) — Rust library crate (`folio_zed_extension`) implementing `FolioZedExtension`, `FolioZedModSession`, cursor-aware folding, $\text{LaTeX}$ math canvas layout, and Zed `v0.8.0` extension bridges.
- [`zed/folio_zed_extension/wasm/`](folio_zed_extension/wasm) — `wasm32-wasip2` `cdylib` crate linking `folio_zed_extension` with `zed_extension_api` (`v0.8.0`) and registering `register_extension!`.
- [`zed/install_extension.sh`](install_extension.sh) — Builds `extension.wasm` and installs the extension bundle into Zed.
