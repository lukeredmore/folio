import Foundation

extension RemoteWorkspaceManager {
    // MARK: - Lazy Directory State

    var loadedDirectoriesDefaultsKey: String { mountsDefaultsKey + ".LoadedDirectories" }

    static func decodeLoadedDirectories(_ raw: [String: Any]) -> [UUID: Set<String>] {
        var result: [UUID: Set<String>] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key), let paths = value as? [String] else { continue }
            result[id] = Set(paths)
        }
        return result
    }

    func persistLoadedDirectories() {
        let encoded = Dictionary(
            uniqueKeysWithValues: loadedRemoteDirectories.map { ($0.key.uuidString, $0.value.sorted()) }
        )
        userDefaults.set(encoded, forKey: loadedDirectoriesDefaultsKey)
    }

    var sidebarFiltersDefaultsKey: String { mountsDefaultsKey + ".SidebarFilters" }

    func persistSidebarFilters() {
        if let data = try? JSONEncoder().encode(sidebarFilters) {
            userDefaults.set(data, forKey: sidebarFiltersDefaultsKey)
        }
    }

    /// The file types and folders that a folder mount hides.
    public func sidebarFilter(for mountID: UUID) -> SidebarRootFilter {
        sidebarFilters[mountID] ?? SidebarRootFilter()
    }

    /// Saves `filter` for a mount, then syncs it so files of shown types download again.
    public func setSidebarFilter(_ filter: SidebarRootFilter, for mountID: UUID) {
        guard sidebarFilter(for: mountID) != filter else { return }
        sidebarFilters[mountID] = filter
        directoryProbes.removeValue(forKey: mountID)
        persistSidebarFilters()
        if let mount = mounts.first(where: { $0.id == mountID }) {
            notifyMirrorUpdated(mount.id, [])
        }
        Task { [weak self] in
            _ = await self?.syncMount(id: mountID, isBackground: false)
        }
    }

    /// Mount-relative directories that each sync lists. Always includes the root (`""`).
    public func loadedDirectories(for mountID: UUID) -> Set<String> {
        (loadedRemoteDirectories[mountID] ?? []).union([""])
    }

    /// True when syncs list the remote directory behind `url`.
    public func isRemoteDirectoryLoaded(at url: URL) -> Bool {
        guard let resolved = resolveMount(for: url) else { return false }
        return loadedDirectories(for: resolved.mount.id).contains(resolved.relativePath)
    }

    /// True when the remote directory behind `url` was listed in this session.
    public func hasListedRemoteDirectory(at url: URL) -> Bool {
        guard let resolved = resolveMount(for: url) else { return false }
        return listedRemoteDirectories[resolved.mount.id]?.contains(resolved.relativePath) ?? false
    }

    /// Whether the unlisted remote directory behind `url` holds a shown document. Nil when not probed yet.
    public func remoteDirectoryHasDocuments(at url: URL) -> Bool? {
        guard let resolved = resolveMount(for: url) else { return nil }
        return directoryProbes[resolved.mount.id]?[resolved.relativePath]?.hasDocuments
    }

    /// Lists the remote directory behind `url` now, and on every later sync.
    @discardableResult
    public func loadRemoteDirectory(at url: URL) async -> Bool {
        guard let resolved = resolveMount(for: url), resolved.mount.targetKind == .folder else { return false }
        let mount = resolved.mount
        let relativePath = resolved.relativePath
        let loadKey = "\(mount.id.uuidString)/\(relativePath)"
        if listedRemoteDirectories[mount.id]?.contains(relativePath) ?? false { return true }
        guard !inFlightDirectoryLoads.contains(loadKey) else { return false }

        inFlightDirectoryLoads.insert(loadKey)
        defer { inFlightDirectoryLoads.remove(loadKey) }
        if !relativePath.isEmpty, loadedRemoteDirectories[mount.id, default: []].insert(relativePath).inserted {
            persistLoadedDirectories()
        }
        do {
            let changedURLs = try await refreshFolderMount(mount, directories: [relativePath])
            notifyMirrorUpdated(mount.id, changedURLs)
            return true
        } catch {
            handleTransportFailure(for: mount, error: error)
            return false
        }
    }

    // MARK: - Listing & Download

    /// Lists `directories`, applies each listing to the mirror, probes unlisted subdirectories,
    /// and downloads files that changed. `refreshAllProbes` ignores cached probe results.
    func refreshFolderMount(
        _ mount: RemoteMountSpec,
        directories: Set<String>,
        refreshAllProbes: Bool = false
    ) async throws -> [URL] {
        let filter = sidebarFilter(for: mount.id)
        let shownDirectories = directories.filter { !filter.excludes(relativePath: $0) }
        guard !shownDirectories.isEmpty else { return [] }
        let shownExtensions = filter.shownExtensions(of: WorkspaceFileNode.remoteDocumentExtensions)
        let listings = try await transport.listDirectories(
            shownDirectories.sorted(),
            fileExtensions: shownExtensions,
            for: mount
        )
        var changedURLs: [URL] = []
        var pathsToFetch: [String] = []
        var listedPaths: [String] = []
        for listing in listings {
            if listing.exists {
                changedURLs += applyListing(listing, for: mount, pathsToFetch: &pathsToFetch)
                listedPaths.append(listing.relativePath)
            } else if !listing.relativePath.isEmpty {
                changedURLs += removeMirrorDirectory(listing.relativePath, for: mount)
            }
        }
        let probePaths = subdirectoriesNeedingProbe(in: listings, for: mount, filter: filter, refreshAll: refreshAllProbes)
        if !probePaths.isEmpty {
            let results = try await transport.probeDirectories(
                probePaths,
                fileExtensions: shownExtensions,
                excludedPaths: filter.excludedPaths,
                for: mount
            )
            let now = Date()
            for (path, hasDocuments) in results {
                directoryProbes[mount.id, default: [:]][path] = RemoteDirectoryProbe(hasDocuments: hasDocuments, checkedAt: now)
            }
        }
        if !pathsToFetch.isEmpty {
            let entries = try await transport.fetchFiles(pathsToFetch, for: mount)
            changedURLs += writeFetchedEntries(entries, for: mount)
        }
        listedRemoteDirectories[mount.id, default: []].formUnion(listedPaths)
        return changedURLs
    }

    /// Subdirectories of `listings` that are not loaded and have no current probe result.
    func subdirectoriesNeedingProbe(
        in listings: [RemoteDirectoryListing],
        for mount: RemoteMountSpec,
        filter: SidebarRootFilter,
        refreshAll: Bool
    ) -> [String] {
        let loaded = loadedDirectories(for: mount.id)
        let probes = directoryProbes[mount.id] ?? [:]
        let oldest = Date().addingTimeInterval(-directoryProbeLifetimeSeconds)
        return listings.filter(\.exists).flatMap { listing in
            let prefix = listing.relativePath.isEmpty ? "" : listing.relativePath + "/"
            return listing.subdirectoryNames.compactMap { name -> String? in
                guard !WorkspaceFileNode.isIgnoredDirectoryName(name) else { return nil }
                let path = prefix + name
                guard !loaded.contains(path), !filter.excludes(relativePath: path) else { return nil }
                if !refreshAll, let probe = probes[path], probe.checkedAt > oldest { return nil }
                return path
            }
        }
    }

    /// Downloads the target of a file mount.
    func refreshFileMount(_ mount: RemoteMountSpec) async throws -> [URL] {
        let filename = (mount.remotePath as NSString).lastPathComponent
        let entries = try await transport.fetchFiles([filename], for: mount)
        return writeFetchedEntries(entries, for: mount)
    }

    func localDirectoryURL(for relativePath: String, in mount: RemoteMountSpec) -> URL {
        let root = localMirrorDirectory(for: mount).standardizedFileURL
        return relativePath.isEmpty ? root : root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
    }

    func pendingWriteURLs(for mount: RemoteMountSpec) -> Set<URL> {
        Set(pendingWriteQueue.filter { $0.mountID == mount.id }.map(\.localFileURL))
    }

    /// Makes one mirror directory match `listing`, and adds files whose mtime or size changed to `pathsToFetch`.
    func applyListing(_ listing: RemoteDirectoryListing, for mount: RemoteMountSpec, pathsToFetch: inout [String]) -> [URL] {
        let fm = FileManager.default
        let directoryURL = localDirectoryURL(for: listing.relativePath, in: mount)
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let pendingURLs = pendingWriteURLs(for: mount)
        let prefix = listing.relativePath.isEmpty ? "" : listing.relativePath + "/"

        let subdirectoryNames = Set(listing.subdirectoryNames.filter { !WorkspaceFileNode.isIgnoredDirectoryName($0) })
        let filter = sidebarFilter(for: mount.id)
        let files = listing.files.filter {
            WorkspaceFileNode.remoteDocumentExtensions.contains(($0.name as NSString).pathExtension.lowercased())
                && filter.showsFile(named: $0.name)
        }
        let fileNames = Set(files.map(\.name))
        for name in subdirectoryNames {
            try? fm.createDirectory(at: directoryURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }

        var changedURLs: [URL] = []
        let existing = (try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for itemURL in existing {
            let name = itemURL.lastPathComponent
            let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if !subdirectoryNames.contains(name) {
                    changedURLs += removeMirrorDirectory(prefix + name, for: mount)
                }
            } else if !fileNames.contains(name) {
                let fileURL = itemURL.standardizedFileURL
                guard !pendingURLs.contains(fileURL) else { continue }
                try? fm.removeItem(at: fileURL)
                lastSyncedContentHashes.removeValue(forKey: fileURL)
                fileSyncStatuses.removeValue(forKey: fileURL)
                changedURLs.append(fileURL)
            }
        }

        for file in files {
            let fileURL = localFileURL(for: prefix + file.name, in: mount)
            guard !pendingURLs.contains(fileURL) else { continue }
            if Self.mirrorFile(at: fileURL, matches: file) {
                if fileSyncStatuses[fileURL] != .synced {
                    fileSyncStatuses[fileURL] = .synced
                }
            } else {
                pathsToFetch.append(prefix + file.name)
            }
        }
        return changedURLs
    }

    /// True when the mirror copy has the same whole-second mtime and byte size as the remote file.
    static func mirrorFile(at url: URL, matches stat: RemoteFileStat) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let date = values.contentModificationDate,
            let size = values.fileSize
        else { return false }
        return Int(date.timeIntervalSince1970) == Int(stat.modificationTimestamp) && size == stat.size
    }

    /// Deletes a mirror directory that is gone from the host, unless it holds an unpushed write.
    func removeMirrorDirectory(_ relativePath: String, for mount: RemoteMountSpec) -> [URL] {
        let directoryURL = localDirectoryURL(for: relativePath, in: mount)
        let directoryPrefix = directoryURL.path + "/"
        guard !pendingWriteURLs(for: mount).contains(where: { $0.path.hasPrefix(directoryPrefix) }) else { return [] }

        var removedURLs: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil) {
            for case let itemURL as URL in enumerator {
                removedURLs.append(itemURL.standardizedFileURL)
            }
        }
        try? FileManager.default.removeItem(at: directoryURL)
        for url in removedURLs {
            lastSyncedContentHashes.removeValue(forKey: url)
            fileSyncStatuses.removeValue(forKey: url)
        }

        let pathPrefix = relativePath + "/"
        let isRemoved = { (path: String) in path == relativePath || path.hasPrefix(pathPrefix) }
        if let listed = listedRemoteDirectories[mount.id] {
            listedRemoteDirectories[mount.id] = listed.filter { !isRemoved($0) }
        }
        directoryProbes[mount.id] = directoryProbes[mount.id]?.filter { !isRemoved($0.key) }
        if let loaded = loadedRemoteDirectories[mount.id], loaded.contains(where: isRemoved) {
            loadedRemoteDirectories[mount.id] = loaded.filter { !isRemoved($0) }
            persistLoadedDirectories()
        }
        return removedURLs + [directoryURL]
    }

    /// Writes downloaded files to the mirror, except files with an unpushed local write.
    func writeFetchedEntries(_ entries: [RemoteFileEntry], for mount: RemoteMountSpec) -> [URL] {
        let pendingURLs = pendingWriteURLs(for: mount)
        var changedURLs: [URL] = []
        for entry in entries {
            let fileURL = localFileURL(for: entry.relativePath, in: mount)
            guard !pendingURLs.contains(fileURL) else { continue }

            if (try? String(contentsOf: fileURL, encoding: .utf8)) != entry.content {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? entry.content.write(to: fileURL, atomically: true, encoding: .utf8)
                changedURLs.append(fileURL)
            }
            if entry.modificationTimestamp > 0 {
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: entry.modificationTimestamp)],
                    ofItemAtPath: fileURL.path
                )
            }
            lastSyncedContentHashes[fileURL] = entry.contentHash
            fileSyncStatuses[fileURL] = .synced
        }
        return changedURLs
    }
}
