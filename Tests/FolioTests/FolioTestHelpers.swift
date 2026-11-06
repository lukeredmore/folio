import Foundation
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace

/// Lists one level of each path in `relativePaths` from a flat `relativePath -> content` map.
/// Reports only files with one of `fileExtensions`.
func mockDirectoryListings(
    _ relativePaths: [String],
    fileExtensions: Set<String>,
    files: [String: String],
    modificationTimestamps: [String: TimeInterval]
) -> [RemoteDirectoryListing] {
    relativePaths.map { directory in
        let prefix = directory.isEmpty ? "" : directory + "/"
        var exists = directory.isEmpty
        var subdirectories: Set<String> = []
        var stats: [RemoteFileStat] = []
        for (path, content) in files where path.hasPrefix(prefix) {
            exists = true
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                subdirectories.insert(String(rest[..<slash]))
            } else if fileExtensions.contains((String(rest) as NSString).pathExtension.lowercased()) {
                stats.append(
                    RemoteFileStat(
                        name: String(rest),
                        modificationTimestamp: modificationTimestamps[path] ?? 0,
                        size: content.utf8.count
                    ))
            }
        }
        return RemoteDirectoryListing(
            relativePath: directory,
            exists: exists,
            subdirectoryNames: subdirectories.sorted(),
            files: stats.sorted { $0.name < $1.name }
        )
    }
}

/// Probes each path in `relativePaths` against a flat `relativePath -> content` map.
func mockDirectoryProbes(
    _ relativePaths: [String],
    fileExtensions: Set<String>,
    excludedPaths: Set<String>,
    files: [String: String]
) -> [String: Bool] {
    let filter = SidebarRootFilter(excludedPaths: excludedPaths)
    let documentPaths = files.keys.filter { path in
        let components = path.split(separator: "/").map(String.init)
        let folders = components.dropLast()
        guard !folders.contains(where: WorkspaceFileNode.isIgnoredDirectoryName) else { return false }
        guard !filter.excludes(relativePath: folders.joined(separator: "/")) else { return false }
        return fileExtensions.contains((path as NSString).pathExtension.lowercased())
    }
    return Dictionary(
        uniqueKeysWithValues: relativePaths.map { directory in
            (directory, documentPaths.contains { $0.hasPrefix(directory + "/") })
        })
}

final class MockRemoteTransport: RemoteFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: [String: String]] = [:]
    private var modificationTimestamps: [UUID: [String: TimeInterval]] = [:]
    private var nextModificationTimestamp: TimeInterval = 1_700_000_000
    private var fetchedPaths: [String] = []
    private var listedPaths: [String] = []
    private var listedExtensions: Set<String>?
    private var probedPaths: [String] = []
    var simulatedError: Error?

    /// Replaces the remote files of a mount. Every file gets a new mtime.
    func setRemoteFiles(for mountID: UUID, files: [String: String]) {
        lock.withLock {
            storage[mountID] = files
            var stamps: [String: TimeInterval] = [:]
            for path in files.keys {
                stamps[path] = takeModificationTimestamp()
            }
            modificationTimestamps[mountID] = stamps
        }
    }

    func getRemoteFile(for mountID: UUID, relativePath: String) -> String? {
        lock.withLock {
            storage[mountID]?[relativePath]
        }
    }

    /// Paths passed to `fetchFiles`, in call order.
    var fetchedRelativePaths: [String] { lock.withLock { fetchedPaths } }

    /// Directories passed to `listDirectories`, in call order.
    var listedRelativePaths: [String] { lock.withLock { listedPaths } }

    /// Directories passed to `probeDirectories`, in call order.
    var probedRelativePaths: [String] { lock.withLock { probedPaths } }

    /// The file extensions of the last `listDirectories` call.
    var lastListedFileExtensions: Set<String>? { lock.withLock { listedExtensions } }

    func resetCallLog() {
        lock.withLock {
            fetchedPaths = []
            listedPaths = []
            probedPaths = []
        }
    }

    private func takeModificationTimestamp() -> TimeInterval {
        nextModificationTimestamp += 1
        return nextModificationTimestamp
    }

    func listDirectories(
        _ relativePaths: [String],
        fileExtensions: Set<String>,
        for mount: RemoteMountSpec
    ) async throws -> [RemoteDirectoryListing] {
        let (err, files, stamps) = lock.withLock {
            listedPaths += relativePaths
            listedExtensions = fileExtensions
            return (simulatedError, storage[mount.id] ?? [:], modificationTimestamps[mount.id] ?? [:])
        }
        if let err {
            throw err
        }
        return mockDirectoryListings(relativePaths, fileExtensions: fileExtensions, files: files, modificationTimestamps: stamps)
    }

    func probeDirectories(
        _ relativePaths: [String],
        fileExtensions: Set<String>,
        excludedPaths: Set<String>,
        for mount: RemoteMountSpec
    ) async throws -> [String: Bool] {
        let (err, files) = lock.withLock {
            probedPaths += relativePaths
            return (simulatedError, storage[mount.id] ?? [:])
        }
        if let err {
            throw err
        }
        return mockDirectoryProbes(relativePaths, fileExtensions: fileExtensions, excludedPaths: excludedPaths, files: files)
    }

    func fetchFiles(_ relativePaths: [String], for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let (err, files, stamps) = lock.withLock {
            fetchedPaths += relativePaths
            return (simulatedError, storage[mount.id] ?? [:], modificationTimestamps[mount.id] ?? [:])
        }
        if let err {
            throw err
        }
        return relativePaths.compactMap { path in
            files[path].map { RemoteFileEntry(relativePath: path, modificationTimestamp: stamps[path] ?? 0, content: $0) }
        }
    }

    func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
        let (err, stamp): (Error?, TimeInterval) = lock.withLock {
            guard simulatedError == nil else { return (simulatedError, 0) }
            storage[mount.id, default: [:]][relativePath] = content
            let stamp = takeModificationTimestamp()
            modificationTimestamps[mount.id, default: [:]][relativePath] = stamp
            return (nil, stamp)
        }

        if let err {
            throw err
        }
        return stamp
    }

    func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {
        let err: Error? = lock.withLock {
            if simulatedError == nil {
                storage[mount.id]?.removeValue(forKey: relativePath)
                modificationTimestamps[mount.id]?.removeValue(forKey: relativePath)
            }
            return simulatedError
        }

        if let err {
            throw err
        }
    }
}

extension XCTestCase {
    /// A view model with isolated defaults and a temporary remote mirror.
    @MainActor
    func makeIsolatedViewModel(defaults: UserDefaults? = nil) -> EditorWorkspaceViewModel {
        let resolvedDefaults = defaults ?? isolatedDefaults()
        let mirror: URL
        do {
            mirror = try makeTemporaryDirectory("FolioMirror")
        } catch {
            preconditionFailure("Could not create a remote mirror directory: \(error)")
        }
        let manager = RemoteWorkspaceManager(mirrorBaseDirectory: mirror, userDefaults: resolvedDefaults)
        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: manager, userDefaults: resolvedDefaults)
        addTeardownBlock {
            vm.stopWatchingCurrentFile()
            vm.stopWatchingWorkspaceFolders()
        }
        return vm
    }
}

extension WorkspacePerfCounters {
    func delta(since earlier: WorkspacePerfCounters) -> WorkspacePerfCounters {
        var result = WorkspacePerfCounters()
        result.undoPersistCount = undoPersistCount - earlier.undoPersistCount
        result.autosaveWriteCount = autosaveWriteCount - earlier.autosaveWriteCount
        return result
    }
}
