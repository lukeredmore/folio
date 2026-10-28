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
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return
            appSupport
            .appendingPathComponent("Folio", isDirectory: true)
            .appendingPathComponent("cli_open_requests.txt")
    }

    public static var defaultCandidateBinDirectories: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        ]
    }

    public static func bundledCLILauncherURL(in appBundleURL: URL = Bundle.main.bundleURL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("folio")
    }

    public static func resolveAppBundlePath(explicitBundleURL: URL? = nil) -> String {
        if let explicit = explicitBundleURL { return explicit.path }
        let mainBundle = Bundle.main.bundleURL
        if mainBundle.pathExtension == "app" { return mainBundle.path }
        let cwdApp = URL(fileURLWithPath: effectiveWorkingDirectoryPath()).appendingPathComponent("Folio.app")
        if FileManager.default.fileExists(atPath: cwdApp.path) { return cwdApp.path }
        return "/Applications/Folio.app"
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
            FileManager.default.isExecutableFile(atPath: existingPath),
            let content = try? String(contentsOfFile: existingPath, encoding: .utf8),
            content.contains("resolve_self_app_bundle")
        {
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
                if let attrs = try? fm.attributesOfItem(atPath: targetURL.path),
                    attrs[.type] as? FileAttributeType == .typeSymbolicLink
                {
                    try? fm.removeItem(at: targetURL)
                }
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
            alert.informativeText =
                "The 'folio' command-line launcher is installed at \(installedURL.path).\n\nOpen files or folders from your terminal with:\nfolio <path>"
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Could Not Install 'folio' Command"
            alert.informativeText = "Could not write to /usr/local/bin or ~/.local/bin."
        }
        alert.runModal()
    }

    public static func drainPendingOpenRequests(from queueFileURL: URL = defaultQueueFileURL) -> [String] {
        guard FileManager.default.fileExists(atPath: queueFileURL.path),
            let content = try? String(contentsOf: queueFileURL, encoding: .utf8)
        else {
            return []
        }
        try? FileManager.default.removeItem(at: queueFileURL)
        return
            content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
