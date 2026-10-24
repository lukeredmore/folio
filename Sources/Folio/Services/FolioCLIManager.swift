import AppKit
import Foundation

/// Manages installation of the `folio` terminal command (`folio <path>`) on first launch
/// and coordinates opening files/folders requested from the command line.
@MainActor
public final class FolioCLIManager {
    public static let shared = FolioCLIManager()

    public static let cliInstalledDefaultsKey = "Folio.CLIInstalled.v1"
    public static let cliInstalledPathDefaultsKey = "Folio.CLIInstalledPath.v1"

    nonisolated(unsafe) private var signalSource: DispatchSourceSignal?
    private var onOpenPathsHandler: (([String]) -> Void)?

    public init() {}

    public static var defaultQueueFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Folio", isDirectory: true)
            .appendingPathComponent("cli_open_requests.txt")
    }

    public static var defaultCandidateBinDirectories: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        ]
    }

    public static func resolveAppBundlePath(explicitBundleURL: URL? = nil) -> String {
        if let explicit = explicitBundleURL { return explicit.path }
        let mainBundle = Bundle.main.bundleURL
        if mainBundle.pathExtension == "app" { return mainBundle.path }
        let cwdApp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Folio.app")
        if FileManager.default.fileExists(atPath: cwdApp.path) { return cwdApp.path }
        return "/Applications/Folio.app"
    }

    /// Generates the executable `folio` shell script (similar to Zed's `zed` CLI launcher).
    public static func generateCLIScript(
        fallbackAppBundlePath: String,
        queueFilePath: String = defaultQueueFileURL.path
    ) -> String {
        """
        #!/usr/bin/env bash
        # Folio CLI launcher — opens Markdown files and folders in Folio.app
        set -euo pipefail
        QUEUE_FILE="\(queueFilePath)"
        FALLBACK_APP="\(fallbackAppBundlePath)"

        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
            echo "Usage: folio [path ...]"
            echo "Open files or folders in Folio."
            exit 0
        fi
        if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
            echo "folio 1.0.0"
            exit 0
        fi

        resolve_app_bundle() {
            for candidate in "${FOLIO_APP_PATH:-}" "/Applications/Folio.app" "$HOME/Applications/Folio.app" "${FALLBACK_APP}"; do
                if [[ -n "${candidate}" && -d "${candidate}" ]]; then
                    echo "${candidate}"
                    return 0
                fi
            done
            local found
            found="$(mdfind "kMDItemCFBundleIdentifier == 'app.folio.macos'" 2>/dev/null | head -n 1 || true)"
            if [[ -n "${found}" && -d "${found}" ]]; then
                echo "${found}"
                return 0
            fi
            return 1
        }

        ABS_PATHS=()
        for arg in "$@"; do
            [[ "${arg}" == -* ]] && continue
            if [[ -d "${arg}" ]]; then
                ABS_PATHS+=("$(cd "${arg}" && pwd -P)")
            else
                if [[ ! -e "${arg}" ]]; then
                    mkdir -p "$(dirname "${arg}")"
                    touch "${arg}"
                fi
                dir_part="$(cd "$(dirname "${arg}")" && pwd -P)"
                ABS_PATHS+=("${dir_part}/$(basename "${arg}")")
            fi
        done

        if (( ${#ABS_PATHS[@]} > 0 )); then
            mkdir -p "$(dirname "${QUEUE_FILE}")"
            for p in "${ABS_PATHS[@]}"; do
                printf '%s\\n' "${p}" >> "${QUEUE_FILE}"
            done
        fi

        RUNNING_PIDS="$(pgrep -x "Folio" 2>/dev/null || pgrep -x "FolioApp" 2>/dev/null || true)"
        if [[ -n "${RUNNING_PIDS}" ]]; then
            for pid in ${RUNNING_PIDS}; do
                kill -USR1 "${pid}" 2>/dev/null || true
            done
            osascript -e 'tell application "System Events" to set frontmost of every process whose name is "Folio" or name is "FolioApp" to true' >/dev/null 2>&1 || true
            exit 0
        fi

        if APP_BUNDLE="$(resolve_app_bundle)"; then
            if (( ${#ABS_PATHS[@]} > 0 )); then
                open -a "${APP_BUNDLE}" --args "${ABS_PATHS[@]}"
            else
                open -a "${APP_BUNDLE}"
            fi
        else
            echo "folio: could not locate Folio.app. Move Folio.app to /Applications or set FOLIO_APP_PATH." >&2
            exit 1
        fi
        """
    }

    @discardableResult
    public func setupCLIOnFirstLaunchIfNeeded(
        candidateBinDirs: [URL]? = nil,
        appBundleURL: URL? = nil,
        queueFileURL: URL = defaultQueueFileURL,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        let alreadyInstalled = userDefaults.bool(forKey: Self.cliInstalledDefaultsKey)
        if alreadyInstalled,
           let existingPath = userDefaults.string(forKey: Self.cliInstalledPathDefaultsKey),
           FileManager.default.isExecutableFile(atPath: existingPath) {
            return URL(fileURLWithPath: existingPath)
        }
        return installCLI(
            into: candidateBinDirs,
            appBundleURL: appBundleURL,
            queueFileURL: queueFileURL,
            userDefaults: userDefaults
        )
    }

    @discardableResult
    public func installCLI(
        into candidateBinDirs: [URL]? = nil,
        appBundleURL: URL? = nil,
        queueFileURL: URL = defaultQueueFileURL,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        let dirs = candidateBinDirs ?? Self.defaultCandidateBinDirectories
        let bundlePath = Self.resolveAppBundlePath(explicitBundleURL: appBundleURL)
        let scriptContent = Self.generateCLIScript(
            fallbackAppBundlePath: bundlePath,
            queueFilePath: queueFileURL.path
        )
        let fm = FileManager.default
        var primaryInstalledURL: URL?

        for dirURL in dirs {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dirURL.path, isDirectory: &isDir) {
                try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            }
            guard fm.isWritableFile(atPath: dirURL.path) else { continue }
            let targetURL = dirURL.appendingPathComponent("folio")
            do {
                try Data(scriptContent.utf8).write(to: targetURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetURL.path)
                if primaryInstalledURL == nil {
                    primaryInstalledURL = targetURL
                }
            } catch {
                continue
            }
        }

        if let installed = primaryInstalledURL {
            userDefaults.set(true, forKey: Self.cliInstalledDefaultsKey)
            userDefaults.set(installed.path, forKey: Self.cliInstalledPathDefaultsKey)
        }
        return primaryInstalledURL
    }

    public func installCLIFromMenu() {
        let installedURL = installCLI()
        let alert = NSAlert()
        if let installedURL {
            alert.alertStyle = .informational
            alert.messageText = "Installed 'folio' Command"
            alert.informativeText = "The 'folio' command-line launcher is installed at \(installedURL.path).\n\nOpen files or folders from your terminal with:\nfolio <path>"
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Could Not Install 'folio' Command"
            alert.informativeText = "Could not write to /usr/local/bin or ~/.local/bin."
        }
        alert.runModal()
    }

    public static func drainPendingOpenRequests(from queueFileURL: URL = defaultQueueFileURL) -> [String] {
        guard FileManager.default.fileExists(atPath: queueFileURL.path),
              let content = try? String(contentsOf: queueFileURL, encoding: .utf8) else {
            return []
        }
        try? FileManager.default.removeItem(at: queueFileURL)
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func extractCommandLinePaths(
        from arguments: [String],
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> [String] {
        guard arguments.count > 1 else { return [] }
        var paths: [String] = []
        var skipNext = false
        for arg in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") || arg.hasPrefix("-psn_") || arg == "-XCTest" {
                if arg == "-NSDocumentRevisionsDebugMode" || arg == "-ApplePersistenceIgnoreState" || arg == "-XCTest" {
                    skipNext = true
                }
                continue
            }
            if arg.hasPrefix("-") || arg.hasSuffix(".xctest") { continue }
            let resolvedURL = arg.hasPrefix("/")
                ? URL(fileURLWithPath: arg).standardizedFileURL
                : URL(fileURLWithPath: currentDirectoryPath).appendingPathComponent(arg).standardizedFileURL
            paths.append(resolvedURL.path)
        }
        return paths
    }

    public func startListeningForCLIOpenSignal(
        queueFileURL: URL = defaultQueueFileURL,
        onOpenPaths: @escaping @MainActor ([String]) -> Void
    ) {
        self.onOpenPathsHandler = onOpenPaths
        guard signalSource == nil else { return }
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                let paths = Self.drainPendingOpenRequests(from: queueFileURL)
                if !paths.isEmpty {
                    onOpenPaths(paths)
                }
            }
        }
        source.resume()
        signalSource = source
    }
}
