# OpenType — Native macOS Markdown Editor

**OpenType** is a lightning-fast, 100% native macOS Markdown editor (`AppKit` + `TextKit` + `SwiftUI`) designed for distraction-free writing and instant live formatting.

---

## Building & Launching

### Build & Run `OpenType.app` Bundle
```bash
chmod +x build_app.sh
./build_app.sh
open OpenType.app
```

### Run via Swift Package Manager
```bash
swift run
```

### Run Unit Tests
```bash
swift test
```

---

## Features & Keyboard Shortcuts

| Feature | Shortcut | Description |
| :--- | :--- | :--- |
| **Seamless Live Mode / Source Code Mode** | `Cmd + /` | Toggle between live inline WYSIWYG Markdown and raw source editing |
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

---

## Included Themes

1. **Daylight** (`#ffffff` background, `#4183C4` links, SF Pro / Helvetica Neue)
2. **Midnight** (`#363B40` dark canvas, `#2E3033` sidebar, `#B8BFC6` body text, `#e0b27e` links)
3. **Parchment** (`#f3f2ee` warm paper canvas, `#1f0909` ink text, PT Serif / Georgia typography)
4. **Editorial** (Charter / Georgia generous editorial typography, `#0076df` accents)
5. **Classic** (`#fefefe` centered serif headings, justified Palatino body)
6. **Modernist** (`#fcfcfc` geometric sans-serif with uppercase centered H1)
