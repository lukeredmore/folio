# OpenType Monorepo

**OpenType** is a Bazel-built monorepo providing a live hybrid WYSIWYG Markdown & LaTeX editing experience across a shared Rust core engine, a standalone native macOS application, and a modified build of the **Zed IDE**.

---

## What This Repository Vends

| Bazel Target | Description |
| :--- | :--- |
| **`//:OpenTypeApp`** | Launches the standalone native macOS **OpenType.app** (`AppKit` + `TextKit` + `SwiftUI`), backed by the Rust `opentype_engine` via C-ABI FFI. Includes all 6 editorial themes, typography & layout settings, sidebar (Outline, File List/Tree, Global Search), Focus Mode, and Typewriter Mode. |
| **`//:opentype_macos_app`** | Builds the signed `OpenType.app` macOS bundle archive (`OpenTypeApp.zip`) via `rules_apple` (`./build_app.sh` extracts this to `./OpenType.app`). |
| **`//:zed_with_opentype_mod`** | Builds and launches the full open-source **Zed IDE** (`zed-industries/zed`) with the **OpenType WYSIWYG Markdown & LaTeX Editor** integrated directly into `crates/editor`. |
| **`//:opentype_zed_extension`** | Packages the companion Zed extension bundle (`extension.toml`, `languages/markdown/outline.scm` heading/code-fence outline queries, and `/math`, `/table`, `/callout`, `/toc` slash commands). |
| **`//core/opentype_engine`** | Shared native Rust engine (`rust_library` + `cc_library` FFI `OpenTypeEngineFFI`) providing single-pass Markdown block/inline span scanning, active-line token folding rules, native $\\text{LaTeX}$ math box layout, document statistics, and theme metrics. |

---

## Building & Running (Bazel)

Use the repo's `./tools/bazel` wrapper (which automatically configures the local Xcode SDK and toolchain):

### 1. Run Zed IDE with the OpenType WYSIWYG Markdown Editor
```bash
./tools/bazel run //:zed_with_opentype_mod
```
Opening any `.md` / Markdown file inside Zed automatically transforms the editor pane into an OpenType WYSIWYG document canvas while keeping all of Zed's native IDE chrome (tabs, file tree, terminal, LSP, outline panel, and light/dark theme) intact:
- **Document Typography & Clean Gutter:** Uses Zed's proportional UI font with comfortable `1.65×` line spacing, soft wrapping, and clean document margins (hiding code line numbers, git diff gutter, fold chevrons, indent guides, and whitespace dots). Code fences, inline `` `code` `` pills, and active table rows automatically switch to Zed's monospace buffer font.
- **Cursor-Aware Live Folding:** Syntax markers (`#`, `**`, `*`, `~~`, `==`, `` ` ``, `[label](url)`, `$...$`, `$$...$$`) fold away on inactive lines and smoothly unfold into raw Markdown when the cursor enters that line or block.
- **Scaled Headings (`H1`–`H6`):** Inactive headings render at true scaled typographic sizes (`H1` `28px` bold + bottom rule, `H2` `22.5px` bold + bottom rule, `H3`–`H6`).
- **Fenced Code Block Cards:** Full-row surface card backgrounds (`highlight_rows`) in monospace font with OpenType's colored-dot **Language Pill Header** (`RUST`, `PYTHON`, etc.).
- **Interactive Task Lists & Styled Bullets:** `- [ ]` and `- [x]` render as clickable GPUI checkboxes that toggle `[ ]` ↔ `[x]` directly in the buffer when clicked (with strikethrough on completed tasks).
- **Structured Tables & LaTeX Math Cards:** Inactive pipe tables render as aligned bordered table cells with bold headers; `$...$` and `$$...$$` expressions render as native GPUI math canvases.

### 2. Build & Run the Standalone macOS `OpenType.app`
Launch directly via Bazel:
```bash
./tools/bazel run //:OpenTypeApp
```
Or build and unpack `./OpenType.app` in the workspace root:
```bash
./build_app.sh
open OpenType.app
```

### 3. Build the Companion Zed Extension Bundle
```bash
./tools/bazel build //:opentype_zed_extension
```

### 4. Run All Monorepo Tests
```bash
./tools/bazel test //...
```
Runs:
- `//core/opentype_engine:opentype_engine_test` (Rust core Markdown, LaTeX math layout, stats, and FFI unit tests)
- `//:OpenTypeTests` (macOS AppKit/SwiftUI + `OpenTypeEngineFFI` integration tests)
- `//zed/opentype_zed_mod:opentype_zed_mod_test` (GPUI WYSIWYG adapter & math canvas tests)
- `//zed/opentype_zed_extension:opentype_zed_extension_test` (Zed extension manifest & Tree-sitter outline tests)
- `//third_party/zed:zed_patched_integration_test` (Verifies the Zed source tree patch wiring)

---

## Repository Layout

```text
├── MODULE.bazel / BUILD.bazel       # Root Bazel module & top-level target aliases
├── core/
│   └── opentype_engine/             # Shared Rust Markdown + LaTeX layout engine & C-ABI FFI
├── Sources/OpenType/                # Standalone macOS app UI, AppKit/TextKit editor, themes & modals
├── macos/
│   ├── OpenTypeApp/                 # macOS application bundle & launcher targets
│   └── OpenTypeEngineBridge/        # Swift bridge over OpenTypeEngineFFI
├── zed/
│   ├── opentype_zed_mod/            # Rust GPUI bridge crate between opentype_engine and Zed
│   └── opentype_zed_extension/      # Companion Zed extension (outline.scm + slash commands)
└── third_party/
    └── zed/
        ├── upstream/                # Imported Zed IDE workspace with OpenType WYSIWYG editor mod
        └── patches/                 # Reproducible git patches applied to third_party/zed/upstream
```

---

## Standalone macOS App Features & Shortcuts

The standalone macOS app (`//:OpenTypeApp`) provides a dedicated writing window with custom themes, layout controls, and workspace navigation:

| Feature | Shortcut | Description |
| :--- | :--- | :--- |
| **Seamless Live Mode / Source Code Mode** | `Cmd + /` | Toggle between live inline WYSIWYG Markdown and raw source editing |
| **Typography & Layout Settings** | `Cmd + ,` | Customize font scale, line height, paragraph spacing, heading underlines, and column width |
| **Focus Mode** | `F8` | Dim all lines/paragraphs except the active cursor line |
| **Typewriter Mode** | `F9` | Keep the active caret line vertically centered while typing |
| **Toggle Sidebar** | `Cmd + Shift + L` | Show or hide the Outline / Files / Global Search sidebar |
| **Outline Panel** | `Cmd + Ctrl + 1` | Jump to hierarchical document outline (`H1`–`H6`) |
| **File List / File Tree** | `Cmd + Ctrl + 2 / 3` | Switch between File List and File Tree workspace views |
| **Quick Open** | `Cmd + P` | Instant spotlight-style file switcher across the workspace |
| **Find & Replace** | `Cmd + Opt + F` | In-document Find and Replace banner |
| **Find in Workspace** | `Cmd + Shift + F` | Multi-file search with Case-Sensitive (`Aa`), Whole-Word (`ab`), and Regex (`.*`) toggles |
| **Word Count Popover** | `Cmd + Shift + W` | Live Words, Lines, Characters, Without Spaces, Selection stats, and Reading Time |
| **Headings 1–6 / Paragraph** | `Cmd + 1..6` / `Cmd + 0` | Apply or clear heading levels on the current line |
| **Bold / Italic / Code** | `Cmd + B` / `Cmd + I` / ``Cmd + ` `` | Wrap selection in inline Markdown formatting |
| **Code Fences / Math Block / Table** | `Cmd + Opt + C / M / T` | Insert syntax-highlighted code block, LaTeX math block, or Markdown table |

### Included macOS App Themes
1. **Daylight** (`#ffffff` background, `#4183C4` links, SF Pro / Helvetica Neue)
2. **Midnight** (`#363B40` dark canvas, `#2E3033` sidebar, `#B8BFC6` body text, `#e0b27e` links)
3. **Parchment** (`#f3f2ee` warm paper canvas, `#1f0909` ink text, PT Serif / Georgia typography)
4. **Editorial** (Charter / Georgia generous editorial typography, `#0076df` accents)
5. **Classic** (`#fefefe` centered serif headings, justified Palatino body)
6. **Modernist** (`#fcfcfc` geometric sans-serif with uppercase centered H1)
