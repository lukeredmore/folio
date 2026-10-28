import Foundation

/// The project files one open LaTeX document uses, read from disk ahead of styling. The restyle
/// path only reads a snapshot; it never touches the file system.
struct LaTeXProjectSnapshot: Sendable {
    /// Changes whenever the content below changes, so styling caches can key on it.
    var version: UInt64 = 0
    var signature = LaTeXProjectSignature()
    var master: LaTeXMasterResolution?
    /// Macros from the master file and its preamble inputs.
    var inheritedMacros: [String: LaTeXMacroDefinition] = [:]
    /// Resolved files of the document's own `\input` paths.
    var inputURLs: [String: URL] = [:]
    /// Macros of each of the document's own `\input` paths.
    var inputMacros: [String: [String: LaTeXMacroDefinition]] = [:]
    var bibEntries: [String: BibTeXEntry] = [:]

    static let empty = LaTeXProjectSnapshot()

    func hasSameContent(as other: LaTeXProjectSnapshot) -> Bool {
        signature == other.signature && master == other.master && inheritedMacros == other.inheritedMacros
            && inputURLs == other.inputURLs && inputMacros == other.inputMacros && bibEntries == other.bibEntries
    }
}

/// Stores project snapshots and refreshes them: synchronously the first time a document is
/// styled, and on a background queue when its signature changes or a watched file changes.
enum LaTeXProjectContext {
    struct Key: Hashable, Sendable {
        let fileURL: URL?
        let baseDirectoryURL: URL?

        init(fileURL: URL?, baseDirectoryURL: URL?) {
            self.fileURL = fileURL?.standardizedFileURL
            self.baseDirectoryURL = baseDirectoryURL?.standardizedFileURL
        }
    }

    /// Posted on the main queue after a background refresh changes a snapshot.
    static let didUpdateNotification = Notification.Name("FolioLaTeXProjectDidUpdate")
    static let factsCache = LaTeXFileFactsCache()
    static let limits = LaTeXProjectLimits()
    private static let maxStoredSnapshots = 32

    private static let lock = NSLock()
    nonisolated(unsafe) private static var snapshots: [Key: LaTeXProjectSnapshot] = [:]
    nonisolated(unsafe) private static var nextVersion: UInt64 = 1
    nonisolated(unsafe) private static var queuedSignatures: [Key: LaTeXProjectSignature] = [:]
    nonisolated(unsafe) private static var refreshingKeys: Set<Key> = []
    private static let queue = DispatchQueue(label: "app.folio.latex-project", qos: .utility)

    static func snapshot(for key: Key) -> LaTeXProjectSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[key]
    }

    /// Resolves the project on the calling thread and stores the result. The version only
    /// changes when the content does.
    @discardableResult
    static func refresh(
        _ key: Key,
        signature: LaTeXProjectSignature,
        fileSystem: LaTeXProjectFileSystem = .live,
        limits: LaTeXProjectLimits = LaTeXProjectContext.limits
    ) -> LaTeXProjectSnapshot {
        var resolved = resolve(key, signature: signature, fileSystem: fileSystem, limits: limits)
        lock.lock()
        defer { lock.unlock() }
        if let previous = snapshots[key], previous.hasSameContent(as: resolved) {
            resolved.version = previous.version
        } else {
            resolved.version = nextVersion
            nextVersion += 1
        }
        if snapshots[key] == nil && snapshots.count >= maxStoredSnapshots, let evicted = snapshots.min(by: { $0.value.version < $1.value.version }) {
            snapshots.removeValue(forKey: evicted.key)
        }
        snapshots[key] = resolved
        return resolved
    }

    /// Queues a background refresh. Requests for the same key coalesce to the latest signature.
    static func scheduleRefresh(_ key: Key, signature: LaTeXProjectSignature) {
        lock.lock()
        queuedSignatures[key] = signature
        let start = refreshingKeys.insert(key).inserted
        lock.unlock()
        guard start else { return }
        queue.async { drainRefreshes(for: key) }
    }

    /// Queues a refresh of every stored snapshot for `fileURL`, for example after a file in its
    /// directory changed on disk.
    static func scheduleRefresh(forFile fileURL: URL) {
        let path = fileURL.standardizedFileURL.path
        lock.lock()
        let matches = snapshots.filter { $0.key.fileURL?.path == path }
        lock.unlock()
        for (key, snapshot) in matches {
            scheduleRefresh(key, signature: snapshot.signature)
        }
    }

    /// Forgets every snapshot and cached file fact. For tests.
    static func removeAll() {
        lock.lock()
        snapshots.removeAll()
        queuedSignatures.removeAll()
        lock.unlock()
        factsCache.removeAll()
    }

    private static func drainRefreshes(for key: Key) {
        while true {
            lock.lock()
            guard let signature = queuedSignatures.removeValue(forKey: key) else {
                refreshingKeys.remove(key)
                lock.unlock()
                return
            }
            let before = snapshots[key]?.version
            lock.unlock()
            if refresh(key, signature: signature).version != before {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: didUpdateNotification, object: nil)
                }
            }
        }
    }

    private static func resolve(
        _ key: Key,
        signature: LaTeXProjectSignature,
        fileSystem: LaTeXProjectFileSystem,
        limits: LaTeXProjectLimits
    ) -> LaTeXProjectSnapshot {
        var resolver = LaTeXProjectResolver(fileSystem: fileSystem, limits: limits, cache: factsCache)
        var snapshot = LaTeXProjectSnapshot(signature: signature)
        let baseDirectory = key.baseDirectoryURL ?? key.fileURL?.deletingLastPathComponent()
        if let fileURL = key.fileURL, let master = resolver.resolveMaster(for: fileURL, signature: signature) {
            snapshot.master = master
            snapshot.inheritedMacros = resolver.inheritedMacros(from: master.url, excluding: fileURL)
        }
        guard let baseDirectory else { return snapshot }
        let masterDirectory = snapshot.master?.url.deletingLastPathComponent()
        for path in signature.inputPaths where snapshot.inputURLs[path] == nil {
            guard let url = resolver.resolveTeXPath(path, in: baseDirectory) ?? masterDirectory.flatMap({ resolver.resolveTeXPath(path, in: $0) })
            else { continue }
            snapshot.inputURLs[path] = url
            snapshot.inputMacros[path] = resolver.macros(ofInput: url, root: url.deletingLastPathComponent())
        }
        snapshot.bibEntries = resolver.bibEntries(files: signature.bibFiles, in: baseDirectory)
        return snapshot
    }
}
