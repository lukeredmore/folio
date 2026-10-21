# Folio Standalone macOS Application (`//:FolioApp`)

[![Download Latest Folio.dmg](https://img.shields.io/badge/Download-Folio.dmg-0076df?style=for-the-badge&logo=apple)](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)

This directory (alongside [`Sources/Folio/`](../Sources/Folio)) contains the target definitions, application bundle configuration, and UI implementation for the standalone native macOS **Folio.app** (`AppKit` + `TextKit` + `SwiftUI`), backed by the shared Rust [`folio_engine`](../core/folio_engine/README.md) via C-ABI FFI.

---

## Download & Rolling Auto-Updates (macOS)

- **Direct Download (Always Latest `main` Build):** [**Download `Folio.dmg`**](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)
- **Built-In Rolling Auto-Updater:** Every push to `main` automatically builds `Folio.dmg`, stamps the monotonically increasing commit count (`CFBundleVersion`), short commit SHA (`FolioCommitSHA`), and Rust engine version (`FolioEngineVersion`), and updates the `latest` GitHub Release.
  - Installed copies of `Folio.app` query the GitHub Releases API (`/repos/lukeredmore/folio/releases/latest`) automatically on launch (toggleable in **Settings (`Cmd + ,`)**) or manually via **Folio → Check for Updates…**.
  - Updates are detected whether the marketing version (`CFBundleShortVersionString`, e.g. `1.0.0`) is bumped **or** only the rolling build number (`CFBundleVersion`) / commit SHA advances.
  - When an update is accepted, `AppUpdateManager` downloads `Folio.dmg`, verifies its SHA-256 digest via `CryptoKit`, mounts the disk image read-only in the background, strips quarantine flags, swaps `Folio.app` in-place, and relaunches.

---

## Features & Keyboard Shortcuts

The standalone macOS app (`//:FolioApp`) provides a dedicated writing window with custom themes, layout controls, and workspace navigation:

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
| **Paragraph Line Wrapping** | `Ctrl + Q` | Source line breaks inside a paragraph render as spaces, so paragraphs wrap to the window. When you leave a paragraph you edited, its source is rewrapped to **Wrap Markdown Source At** (Settings, default 80 columns, or Off). **Paragraph > Reflow Paragraph / Reflow Document** rewrap on demand |
| **Bold / Italic / Code** | `Cmd + B` / `Cmd + I` / ``Cmd + ` `` | Wrap selection in inline Markdown formatting |
| **Code Fences / Math Block / Table** | `Cmd + Opt + C / M / T` | Insert syntax-highlighted code block, LaTeX math block, or Markdown table |

### Included macOS App Themes
1. **Daylight** (`#ffffff` background, `#4183C4` links, SF Pro / Helvetica Neue)
2. **Midnight** (`#363B40` dark canvas, `#2E3033` sidebar, `#B8BFC6` body text, `#e0b27e` links)
3. **Parchment** (`#f3f2ee` warm paper canvas, `#1f0909` ink text, PT Serif / Georgia typography)
4. **Editorial** (Charter / Georgia generous editorial typography, `#0076df` accents)
5. **Classic** (`#fefefe` centered serif headings, justified Palatino body)
6. **Modernist** (`#fcfcfc` geometric sans-serif with uppercase centered H1)

---

## Building & Packaging Locally

### 1. Run Directly via Bazel (Dev Build)
```bash
bazel run //:FolioApp
```
Dev builds launched via Bazel display the **DEV**-badged app icon in the macOS Dock.

### 2. Build Stamped `./Folio.app` Bundle
```bash
./build_app.sh
open Folio.app
```

### 3. Package Distributable `Folio.dmg`
```bash
./scripts/package_dmg.sh
```
Produces `./Folio.dmg` (compressed `UDZO` disk image containing `Folio.app` and an `/Applications` drag-and-drop shortcut).

---

## CI / GitHub Actions Workflow (`.github/workflows/release-macos.yml`)

- **On Pull Requests (`pull_request` to `main`):** Runs tests, builds `Folio.dmg` and `Folio-Zed.dmg`, and uploads them as downloadable **GitHub Actions workflow artifacts** on the PR check run without modifying the production `latest` GitHub Release.
- **On Pushes to `main` (`push` to `main`):** Runs tests, builds `Folio.dmg` and `Folio-Zed.dmg`, and updates the rolling `latest` GitHub Release so one-click download links and in-app auto-updates immediately serve the new builds.
- **Manual Trigger (`workflow_dispatch`):** Can be triggered on any branch from the GitHub Actions tab or via `gh workflow run release-macos.yml --ref <branch>`.

---

## Code Signing & GitHub Actions Secrets

Nothing sensitive is ever committed to the repository. By default, if no signing secrets are present, `build_app.sh` and `build_zed_app.sh` fall back to ad-hoc signing (`-`).

To have GitHub Actions sign the app bundles and DMGs with your Apple Developer certificate:

1. Ensure you have an active signing certificate in your Mac's Keychain (**Xcode → Settings (`Cmd + ,`) → Accounts → Manage Certificates… → `+`**):
   - Choose **Developer ID Application** (if enrolled in the paid Apple Developer Program, required for public Gatekeeper notarization), or
   - Choose **Apple Development** (included with any Apple ID / Personal Team; binds the apps to your Team ID across updates so macOS TCC permissions persist).
2. Run the interactive helper script to export your certificate from Keychain into an encrypted temporary `.p12`, upload the secrets to GitHub via `gh secret set`, and immediately shred the temporary file:
   ```bash
   ./scripts/setup_github_signing_secrets.sh
   ```
   This configures:
   - `APPLE_CERTIFICATE_P12_BASE64` — Base64-encoded PKCS#12 certificate + private key
   - `APPLE_CERTIFICATE_PASSWORD` — Randomly generated encryption passphrase for the `.p12`
   - `APPLE_CODESIGN_IDENTITY` — Signing identity common name
   - *(Optional, for `Developer ID Application` notarization)* `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`
