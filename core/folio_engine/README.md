# Folio Core Engine (`//core/folio_engine`)

`folio_engine` is the shared native Rust engine powering both the standalone macOS application ([`//:FolioApp`](../../macos/README.md)) and the Folio-modded Zed IDE ([`//:zed_with_folio_mod`](../../zed/README.md)).

---

## Responsibilities

- **Single-Pass Markdown Scanning (`src/markdown/`)**:
  - Backed by `cmark-gfm` (`//third_party/cmark_gfm`) plus custom inline/block scanners.
  - Produces block decorations (headings `H1`–`H6`, fenced code blocks with language badges, GFM pipe tables, blockquotes/callouts, task lists, horizontal rules, display math `$$...$$`, and Mermaid diagrams) and inline spans (`**bold**`, `*italic*`, `~~strikethrough~~`, `==highlight==`, `` `code` ``, `[links](url)`, `![images](url)`, `$math$`, and inline HTML).
  - Computes cursor-aware active-line syntax reveal vs. inactive-line delimiter folding ranges.
- **Native $\text{LaTeX}$ Math Layout (`src/math/`)**:
  - Parses $\text{LaTeX}$ math expressions into a recursive box layout tree (`MathLayoutBox`, glyphs, fractions, radicals, scripts, matrices, and delimiters) for native CoreGraphics (macOS) and GPUI (Zed) rendering without a webview.
- **Paragraph Source Reflow (`src/reflow/`)**:
  - Rewraps Markdown paragraphs to a configurable column width while preserving protected spans (inline math, links, code spans, list markers, and blockquotes).
- **Document Statistics & Theme Metrics (`src/stats.rs`, `src/theme.rs`)**:
  - Calculates live word, character, line, and reading-time statistics and vends shared typography/theme palettes.
- **C-ABI FFI (`src/ffi/`, `include/folio_engine.h`)**:
  - Exposes `FolioEngineFFI` (`cc_library` with `swift_interop_hint`) consumed directly by Swift 6 in `Sources/Folio/`.

---

## Building & Testing

```bash
# Run all core engine unit, cmark-gfm spec, scan, reflow, and declarative behavior tests
bazel test //core/folio_engine/...

# Or run via Cargo
cargo test -p folio_engine
```

Shared cross-product behavior specifications live in [`tst/specs/*.json`](../../tst/specs) and are verified against `folio_engine`, `folio_zed_mod`, and `FolioTests`.
