import AppKit
import CryptoKit
import Foundation
import SwiftUI

@MainActor
public final class AppUpdateManager: ObservableObject {
    public static let shared = AppUpdateManager()

    public enum Status: Equatable {
        case idle
        case checking
        case upToDate(AppVersionInfo)
        case updateAvailable(ReleaseManifest)
        case downloading(ReleaseManifest)
        case installing(ReleaseManifest)
        case error(String)
    }

    @Published public var status: Status = .idle
    @Published public var showUpdateSheet: Bool = false
    @AppStorage("folio.autoCheckForUpdates") public var autoCheckForUpdates: Bool = true

    public let currentVersion: AppVersionInfo

    public var isRunningDevBuild: Bool {
        currentVersion.isDevBuild
    }

    public init(currentVersion: AppVersionInfo = .current()) {
        self.currentVersion = currentVersion
    }

    /// Evaluates whether a remote release manifest is newer than the currently running build.
    /// Supports both semantic version bumps (`1.0.0` -> `1.1.0`) and rolling builds without version changes
    /// (`1.0.0` build #41 -> `1.0.0` build #42, or differing commit SHA on the same build number).
    /// Dev/debug builds never report an update available against published releases.
    public nonisolated static func isUpdateAvailable(
        current: AppVersionInfo,
        remote: ReleaseManifest
    ) -> Bool {
        if current.isDevBuild {
            return false
        }
        let versionOrder = remote.version.compare(current.shortVersion, options: .numeric)
        if versionOrder == .orderedDescending {
            return true
        }
        if remote.buildNumber > current.buildNumber {
            return true
        }
        if remote.buildNumber == current.buildNumber,
           !current.commitSHA.isEmpty,
           current.commitSHA != "dev",
           !remote.commitSHA.isEmpty,
           !remote.commitSHA.hasPrefix(current.commitSHA),
           !current.commitSHA.hasPrefix(remote.commitSHA) {
            return true
        }
        return false
    }

    /// Verify hex SHA-256 digest of a downloaded file.
    public nonisolated static func verifySHA256(fileURL: URL, expectedHex: String) throws -> Bool {
        let normalizedExpected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedExpected.isEmpty {
            return true
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        return actualHex == normalizedExpected
    }

    public var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(currentVersion.repository)/releases/latest")!
    }

    public func checkForUpdatesOnLaunchIfNeeded() {
        guard autoCheckForUpdates, !isRunningDevBuild else { return }
        Task {
            await checkForUpdates(userInitiated: false)
        }
    }

    public func checkForUpdates(userInitiated: Bool) async {
        guard userInitiated || !isRunningDevBuild else { return }
        status = .checking
        if userInitiated {
            showUpdateSheet = true
        }

        do {
            var request = URLRequest(url: latestReleaseAPIURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                if userInitiated {
                    status = .error("No published GitHub Release found yet.")
                } else {
                    status = .idle
                }
                return
            }

            let manifest = try ReleaseManifest.fromGitHubReleaseAPI(
                data: data,
                defaultRepository: currentVersion.repository
            )
            if Self.isUpdateAvailable(current: currentVersion, remote: manifest) {
                status = .updateAvailable(manifest)
                showUpdateSheet = true
            } else {
                status = .upToDate(currentVersion)
            }
        } catch {
            if userInitiated {
                status = .error("Update check failed: \(error.localizedDescription)")
            } else {
                status = .idle
            }
        }
    }

    public func downloadAndInstallUpdate(_ manifest: ReleaseManifest) async {
        guard let dmgURL = URL(string: manifest.dmgURL) else {
            status = .error("Invalid DMG download URL: \(manifest.dmgURL)")
            return
        }

        status = .downloading(manifest)

        do {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("folio-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            let downloadedDMG = tempRoot.appendingPathComponent("Folio.dmg")
            let (tempFileURL, response) = try await URLSession.shared.download(from: dmgURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                status = .error("Failed to download Folio.dmg from GitHub Releases.")
                return
            }

            if FileManager.default.fileExists(atPath: downloadedDMG.path) {
                try FileManager.default.removeItem(at: downloadedDMG)
            }
            try FileManager.default.moveItem(at: tempFileURL, to: downloadedDMG)

            let checksumValid = try Self.verifySHA256(fileURL: downloadedDMG, expectedHex: manifest.dmgSHA256)
            guard checksumValid else {
                status = .error("Downloaded DMG failed SHA-256 integrity verification.")
                return
            }

            status = .installing(manifest)
            try await Task.detached(priority: .userInitiated) {
                try Self.mountExtractAndScheduleSwap(dmgURL: downloadedDMG, workDir: tempRoot)
            }.value

            // Dismiss the modal sheet and any AppKit attached sheets first, because AppKit
            // ignores NSApplication.shared.terminate(nil) while a window has an attached sheet.
            showUpdateSheet = false
            for window in NSApplication.shared.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
            }
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Darwin.exit(0)
            }
        } catch {
            status = .error("Failed to install update: \(error.localizedDescription)")
        }
    }

    nonisolated static func mountExtractAndScheduleSwap(dmgURL: URL, workDir: URL) throws {
        let mountPoint = workDir.appendingPathComponent("mnt", isDirectory: true)
        let stagedApp = workDir.appendingPathComponent("Folio.app", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachProc = Process()
        attachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attachProc.arguments = [
            "attach",
            "-nobrowse",
            "-readonly",
            "-noverify",
            "-mountpoint", mountPoint.path,
            dmgURL.path,
        ]
        try attachProc.run()
        attachProc.waitUntilExit()
        guard attachProc.terminationStatus == 0 else {
            throw NSError(
                domain: "AppUpdateManager",
                code: Int(attachProc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "hdiutil failed to mount Folio.dmg"]
            )
        }

        defer {
            let detachProc = Process()
            detachProc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detachProc.arguments = ["detach", mountPoint.path, "-force"]
            try? detachProc.run()
            detachProc.waitUntilExit()
        }

        let mountedApp = mountPoint.appendingPathComponent("Folio.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw NSError(
                domain: "AppUpdateManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Folio.app not found inside mounted DMG"]
            )
        }

        let dittoProc = Process()
        dittoProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProc.arguments = [mountedApp.path, stagedApp.path]
        try dittoProc.run()
        dittoProc.waitUntilExit()

        let xattrProc = Process()
        xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrProc.arguments = ["-cr", stagedApp.path]
        try? xattrProc.run()
        xattrProc.waitUntilExit()

        // Determine target .app path to replace
        let runningBundleURL = Bundle.main.bundleURL
        let targetAppPath: String
        if runningBundleURL.pathExtension == "app" && !runningBundleURL.path.hasPrefix("/Volumes/") {
            targetAppPath = runningBundleURL.path
        } else {
            targetAppPath = "/Applications/Folio.app"
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let updaterScript = workDir.appendingPathComponent("apply_update.sh")
        let scriptContents = """
        #!/usr/bin/env bash
        set -euo pipefail
        for _ in {1..10}; do
            if ! kill -0 \(currentPID) 2>/dev/null; then
                break
            fi
            sleep 0.2
        done
        if kill -0 \(currentPID) 2>/dev/null; then
            kill -TERM \(currentPID) 2>/dev/null || true
            sleep 0.3
            kill -9 \(currentPID) 2>/dev/null || true
        fi
        rm -rf "\(targetAppPath)"
        mv "\(stagedApp.path)" "\(targetAppPath)"
        open -n "\(targetAppPath)"
        rm -rf "\(workDir.path)"
        """
        try scriptContents.write(to: updaterScript, atomically: true, encoding: .utf8)

        let swapProc = Process()
        swapProc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        swapProc.arguments = ["/bin/bash", updaterScript.path]
        swapProc.standardInput = FileHandle.nullDevice
        swapProc.standardOutput = FileHandle.nullDevice
        swapProc.standardError = FileHandle.nullDevice
        try swapProc.run()
    }
}
