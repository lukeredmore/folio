# Folio Standalone macOS Application (`//:FolioApp`)

[![Download Latest Folio.dmg](https://img.shields.io/badge/Download-Folio.dmg%20(macOS%2014%2B)-0076df?style=for-the-badge&logo=apple)](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)

This directory contains the target definitions and bundle configuration for the standalone native macOS **Folio.app** (`AppKit` + `TextKit` + `SwiftUI`), backed by the shared Rust `folio_engine` via C-ABI FFI.

---

## Download & Rolling Auto-Updates (macOS)

- **Direct Download (Always Latest `main` Build):** [**Download `Folio.dmg`**](https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg)
- **Built-In Rolling Auto-Updater:** Every push to `main` automatically builds `Folio.dmg`, stamps the monotonically increasing commit count (`CFBundleVersion`), short commit SHA (`FolioCommitSHA`), and Rust engine version (`FolioEngineVersion`), and updates the `latest` GitHub Release.
  - Installed copies of `Folio.app` query the GitHub Releases API (`/repos/lukeredmore/folio/releases/latest`) automatically on launch (toggleable in **Settings (`Cmd + ,`)**) or manually via **Folio → Check for Updates…**.
  - Updates are detected whether the marketing version (`CFBundleShortVersionString`, e.g. `1.0.0`) is bumped **or** only the rolling build number (`CFBundleVersion`) / commit SHA advances.
  - When an update is accepted, `AppUpdateManager` downloads `Folio.dmg`, verifies its SHA-256 digest via `CryptoKit`, mounts the disk image read-only in the background, strips quarantine flags, swaps `Folio.app` in-place, and relaunches.

---

## Building & Packaging Locally

### 1. Run Directly via Bazel
```bash
bazel run //:FolioApp
```

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

- **On Pull Requests (`pull_request` to `main`):** Runs `bazel test //core/folio_engine:folio_engine_test //:FolioTests`, builds `Folio.dmg`, and uploads it as a downloadable **GitHub Actions workflow artifact** (`Folio-macos-dmg`) on the PR check run without modifying the production `latest` GitHub Release.
- **On Pushes to `main` (`push` to `main`):** Runs tests, builds `Folio.dmg`, and updates the rolling `latest` GitHub Release so `https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg` and in-app auto-updates immediately serve the new build.
- **Manual Trigger (`workflow_dispatch`):** Can be triggered on any branch from the GitHub Actions tab or via `gh workflow run release-macos.yml --ref <branch>`.

---

## Code Signing & GitHub Actions Secrets

Nothing sensitive is ever committed to the repository. By default, if no signing secrets are present, `build_app.sh` falls back to ad-hoc signing (`-`).

To have GitHub Actions sign `Folio.app` and `Folio.dmg` with your Apple Developer certificate:

1. Ensure you have an active signing certificate in your Mac's Keychain (**Xcode → Settings (`Cmd + ,`) → Accounts → Manage Certificates… → `+`**):
   - Choose **Developer ID Application** (if enrolled in the paid Apple Developer Program, required for public Gatekeeper notarization), or
   - Choose **Apple Development** (included with any Apple ID / Personal Team; binds `Folio.app` to your Team ID across updates so macOS TCC permissions persist).
2. Run the interactive helper script to export your certificate from Keychain into an encrypted temporary `.p12`, upload the secrets to GitHub via `gh secret set`, and immediately shred the temporary file:
   ```bash
   ./scripts/setup_github_signing_secrets.sh
   ```
   This configures:
   - `APPLE_CERTIFICATE_P12_BASE64` — Base64-encoded PKCS#12 certificate + private key
   - `APPLE_CERTIFICATE_PASSWORD` — Randomly generated encryption passphrase for the `.p12`
   - `APPLE_CODESIGN_IDENTITY` — Signing identity common name
   - *(Optional, for `Developer ID Application` notarization)* `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`
