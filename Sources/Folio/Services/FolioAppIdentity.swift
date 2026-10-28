import Foundation

/// Names the state that one build of Folio owns, derived from its bundle ID.
///
/// Dev builds use their own bundle ID, so their preferences, queue file, caches, and launcher
/// stay apart from the installed release app.
public struct FolioAppIdentity: Equatable, Sendable {
    public static let releaseBundleIdentifier = "app.folio.macos"
    public static let devBundleIdentifier = "app.folio.macos.dev"
    public static let current = FolioAppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)

    public let bundleIdentifier: String

    /// A missing bundle ID resolves to the dev ID, so an unbundled process never uses release state.
    public init(bundleIdentifier: String?) {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.bundleIdentifier = trimmed.isEmpty ? Self.devBundleIdentifier : trimmed
    }

    public var isRelease: Bool {
        bundleIdentifier == Self.releaseBundleIdentifier
    }

    /// Release keeps `name`, the path it used before dev builds had their own ID.
    public func scopedName(_ name: String) -> String {
        isRelease ? name : "\(name)-\(bundleIdentifier)"
    }

    public var cliCommandName: String {
        isRelease ? "folio" : "folio-dev"
    }

    public var signpostSubsystem: String {
        bundleIdentifier
    }

    public func applicationSupportDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(scopedName("Folio"), isDirectory: true)
    }

    public func cliQueueFileURL(in applicationSupport: URL) -> URL {
        applicationSupportDirectory(in: applicationSupport).appendingPathComponent("cli_open_requests.txt")
    }

    public func remoteMirrorRootURL(in caches: URL) -> URL {
        caches.appendingPathComponent(scopedName("FolioRemoteMirrors"), isDirectory: true)
    }

    public func remoteMediaDirectory(in temporaryDirectory: URL) -> URL {
        temporaryDirectory.appendingPathComponent(scopedName("folio-remote-media"), isDirectory: true)
    }

    public func sshControlSocketPath(hash: String) -> String {
        "/tmp/\(scopedName("folio-ssh"))-\(hash).sock"
    }
}
