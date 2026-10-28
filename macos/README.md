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
| **Tabs** | `Cmd + T` | Open a new tab. Each tab edits its own document, and the tab shows the file name. Right-click a file in the sidebar and choose **Open in New Tab**. A file can be open in several tabs: a save in one tab updates the others, and they share the file's undo history. Preferences and recent files are shared by all tabs |
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

## Building, Running & CLI Usage

### 1. Run Directly via Bazel with CLI Arguments (Dev Build)
Both `//:FolioApp` and `//:folio` accept the same CLI flags and `[path[:line[:column]] ...]` arguments, resolving relative paths against the caller's working directory (`BUILD_WORKING_DIRECTORY`):
```bash
# Launch FolioApp and open README.md at line 20, column 1
bazel run //:FolioApp -- README.md:20:1

# Open a workspace folder or print CLI help/version
bazel run //:FolioApp -- .
bazel run //:FolioApp -- --help
bazel run //:folio -- README.md:20:1
```
Dev builds launched via Bazel display the **DEV**-badged app icon in the macOS Dock and run as **Folio Dev** (bundle ID `app.folio.macos.dev`). `FolioAppIdentity` derives their state from the bundle ID, so it stays apart from the installed `Folio.app`:

| State | Release (`app.folio.macos`) | Dev (`app.folio.macos.dev`) |
|---|---|---|
| Preferences | `~/Library/Preferences/app.folio.macos.plist` | `~/Library/Preferences/app.folio.macos.dev.plist` |
| CLI open queue | `~/Library/Application Support/Folio/` | `~/Library/Application Support/Folio-app.folio.macos.dev/` |
| Remote mirrors | `~/Library/Caches/FolioRemoteMirrors` | `~/Library/Caches/FolioRemoteMirrors-app.folio.macos.dev` |
| SSH control sockets | `/tmp/folio-ssh-<hash>.sock` | `/tmp/folio-ssh-app.folio.macos.dev-<hash>.sock` |
| `folio` command | Installed on first launch | Not installed on launch; the menu item installs `folio-dev` |
| Updates | Checked and installed | Never installed |
| Document types | `LSHandlerRank` `Alternate` | `LSHandlerRank` `None` |

The `folio` launcher sends `SIGUSR1` only to running processes whose app has the bundle ID of the app that it opens. For screenshots and manual checks, use a dev build, open a copy of the project, and never send clicks or keystrokes to its window.

### 2. Bundled `folio` CLI in `Folio.app` & `Folio.dmg`
Every `Folio.app` bundle (including inside `Folio.dmg`) embeds the executable `folio` CLI launcher at `Folio.app/Contents/Resources/bin/folio`:
- **Automatic Setup:** On first launch, a release `Folio.app` writes the `folio` launcher to each writable directory of `/usr/local/bin` and `~/.local/bin`. Dev builds skip this step.
- **Manual / `/usr/local/bin` Setup:** Choose **Folio → Install 'folio' Command in PATH…** from the menu bar (or **Settings (`Cmd + ,`) → General → Command Line Tool**) to symlink `/usr/local/bin/folio -> /Applications/Folio.app/Contents/Resources/bin/folio`.
- **Supported CLI Arguments:**
  ```bash
  folio note.md                # Open or create note.md in the running Folio instance
  folio note.md:42:5           # Open note.md and jump cursor to line 42, column 5
  folio ~/notes .              # Set workspace folder and open files
  folio --foreground note.md   # Run Folio attached to the terminal
  folio --help / --version
  ```

### 3. Build the Stamped Release `Folio.app` Bundle
```bash
bazel build --config=release //:FolioApp
open bazel-bin/macos/FolioApp/FolioApp_archive-root/Folio.app
```
`--config=release` builds with `-c opt` and stamps `CFBundleVersion` (commit count), `FolioCommitSHA`, `FolioBuildChannel=release`, `FolioEngineVersion` (from `core/folio_engine/Cargo.toml`), and the release icon. Set `FOLIO_VERSION` to override `CFBundleShortVersionString`. To install the `folio` command, use **Folio → Install 'folio' Command in PATH…**.

### 4. Package Distributable `Folio.dmg`
```bash
bazel build --config=release //:FolioDmg
```
Produces `bazel-bin/macos/FolioApp/Folio.dmg` (compressed `UDZO` disk image containing `Folio.app` with `Contents/Resources/bin/folio` and an `/Applications` drag-and-drop shortcut). `hdiutil` is not hermetic, so this action runs locally without the Bazel sandbox.

---

## CI / GitHub Actions Workflow (`.github/workflows/release-macos.yml`)

- **On Pull Requests (`pull_request` to `main`):** Runs tests, builds `Folio.dmg` and `Folio-Zed.dmg`, and uploads them as downloadable **GitHub Actions workflow artifacts** on the PR check run without modifying the production `latest` GitHub Release.
- **On Pushes to `main` (`push` to `main`):** Runs tests, builds `Folio.dmg` and `Folio-Zed.dmg`, and updates the rolling `latest` GitHub Release so one-click download links and in-app auto-updates immediately serve the new builds.
- **Manual Trigger (`workflow_dispatch`):** Can be triggered on any branch from the GitHub Actions tab or via `gh workflow run release-macos.yml --ref <branch>`.

---

## Code Signing & GitHub Actions Secrets

Nothing sensitive is ever committed to the repository. By default, Bazel signs `Folio.app` ad hoc (`-`). To sign with a certificate from your keychain, build `//:FolioDmg` with `--//tools/release:codesign_identity="<identity>"`. That re-signs the `Folio.app` in the DMG with the hardened runtime and a timestamp, and signs `Folio.dmg`. CI notarizes and staples the DMG when the notarization secrets are set.

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
