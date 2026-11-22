import Darwin
import FolioModels
import Foundation

private struct DirectoryWatchSubscriber {
    let onChanged: @MainActor () -> Void
    let onInvalidated: @Sendable () -> Void
}

private struct SharedDirectoryEntry {
    let source: DispatchSourceFileSystemObject
    let descriptor: Int32
    let inode: UInt64
    var subscribers: [UUID: DirectoryWatchSubscriber]
}

final class SharedDirectoryWatchHub: @unchecked Sendable {
    static let shared = SharedDirectoryWatchHub()

    private let lock = NSLock()
    let maxProcessDirectories: Int
    let reservedDescriptorHeadroom: Int
    let softOpenFileLimitProvider: @Sendable () -> Int
    private var entries: [String: SharedDirectoryEntry] = [:]

    init(
        maxProcessDirectories: Int = 512,
        reservedDescriptorHeadroom: Int = FolioProcessLimits.reservedDescriptorHeadroom,
        softOpenFileLimitProvider: @escaping @Sendable () -> Int = { FolioProcessLimits.currentSoftOpenFileLimit() }
    ) {
        self.maxProcessDirectories = maxProcessDirectories
        self.reservedDescriptorHeadroom = reservedDescriptorHeadroom
        self.softOpenFileLimitProvider = softOpenFileLimitProvider
    }

    var activeDescriptorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func activeDescriptorKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.keys)
    }

    func subscribe(
        watcherID: UUID,
        key: String,
        url: URL,
        currentInode: UInt64,
        onChanged: @escaping @MainActor () -> Void,
        onInvalidated: @escaping @Sendable () -> Void
    ) -> Bool {
        let subscriber = DirectoryWatchSubscriber(onChanged: onChanged, onInvalidated: onInvalidated)
        var staleSource: DispatchSourceFileSystemObject?
        var inheritedSubscribers: [UUID: DirectoryWatchSubscriber] = [:]
        let maxAllowedDescriptor: Int32
        let effectiveMaxDirectories: Int

        lock.lock()
        let softLimit = max(32, softOpenFileLimitProvider())
        effectiveMaxDirectories = min(maxProcessDirectories, max(16, softLimit - reservedDescriptorHeadroom))
        maxAllowedDescriptor = Int32(clamping: max(16, softLimit - reservedDescriptorHeadroom))

        if var existing = entries[key] {
            if existing.inode == currentInode {
                existing.subscribers[watcherID] = subscriber
                entries[key] = existing
                lock.unlock()
                return true
            }
            entries.removeValue(forKey: key)
            staleSource = existing.source
            inheritedSubscribers = existing.subscribers
        }
        let atCapacity = entries.count >= effectiveMaxDirectories
        lock.unlock()

        staleSource?.cancel()
        guard !atCapacity else { return false }

        let dirFD = open(url.path, O_EVTONLY)
        guard dirFD >= 0 else { return false }
        if dirFD >= maxAllowedDescriptor {
            close(dirFD)
            return false
        }

        lock.lock()
        if var existing = entries[key], existing.inode == currentInode {
            existing.subscribers[watcherID] = subscriber
            entries[key] = existing
            lock.unlock()
            close(dirFD)
            return true
        }
        if entries.count >= effectiveMaxDirectories {
            lock.unlock()
            close(dirFD)
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .extend, .attrib, .delete, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let flags = source?.data ?? []
            self?.handleDirectoryEvent(forKey: key, source: source, flags: flags)
        }
        source.setCancelHandler {
            close(dirFD)
        }

        var mergedSubscribers = inheritedSubscribers
        mergedSubscribers[watcherID] = subscriber
        entries[key] = SharedDirectoryEntry(
            source: source,
            descriptor: dirFD,
            inode: currentInode,
            subscribers: mergedSubscribers
        )
        lock.unlock()
        source.resume()
        return true
    }

    func unsubscribe(watcherID: UUID, keys: some Sequence<String>) {
        var sourcesToCancel: [DispatchSourceFileSystemObject] = []
        lock.lock()
        for key in keys {
            guard var entry = entries[key] else { continue }
            entry.subscribers.removeValue(forKey: watcherID)
            if entry.subscribers.isEmpty {
                entries.removeValue(forKey: key)
                sourcesToCancel.append(entry.source)
            } else {
                entries[key] = entry
            }
        }
        lock.unlock()
        for source in sourcesToCancel {
            source.cancel()
        }
    }

    private func handleDirectoryEvent(
        forKey key: String,
        source: DispatchSourceFileSystemObject?,
        flags: DispatchSource.FileSystemEvent
    ) {
        let subscribers: [DirectoryWatchSubscriber]
        let invalidatedSource: DispatchSourceFileSystemObject?
        lock.lock()
        guard let entry = entries[key], let source, entry.source === source else {
            lock.unlock()
            return
        }
        subscribers = Array(entry.subscribers.values)
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            entries.removeValue(forKey: key)
            invalidatedSource = entry.source
        } else {
            invalidatedSource = nil
        }
        lock.unlock()

        if let invalidatedSource {
            for subscriber in subscribers {
                subscriber.onInvalidated()
            }
            invalidatedSource.cancel()
        }
        MainActor.assumeIsolated {
            for subscriber in subscribers {
                subscriber.onChanged()
            }
        }
    }
}

final class POSIXWorkspaceFileWatcher: @unchecked Sendable {
    private static let didEnsureProcessLimits: Void = {
        FolioProcessLimits.raiseOpenFileLimitIfNeeded()
    }()

    private let watcherID = UUID()
    private let directoryWatchHub: SharedDirectoryWatchHub
    private let lock = NSLock()
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var parentDirWatchSource: DispatchSourceFileSystemObject?
    private var fileWatchDescriptor: Int32 = -1
    private var parentDirWatchDescriptor: Int32 = -1
    private var currentWatchedFileInode: UInt64 = 0
    private var watchedDirectoryKeySet: Set<String> = []
    private var pendingFolderWatchReloadWorkItem: DispatchWorkItem?

    init(directoryWatchHub: SharedDirectoryWatchHub = .shared) {
        _ = Self.didEnsureProcessLimits
        self.directoryWatchHub = directoryWatchHub
    }

    deinit {
        stopAll()
    }

    var watchedFileInode: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentWatchedFileInode
    }

    var parentDirectoryDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return parentDirWatchDescriptor
    }

    var watchedDirectoryKeys: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return watchedDirectoryKeySet
    }

    static func isSystemTemporaryRootDirectory(_ url: URL) -> Bool {
        let stdPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let systemTempRoots: Set<String> = [
            "/",
            "/tmp",
            "/private/tmp",
            "/var/tmp",
            "/private/var/tmp",
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        return systemTempRoots.contains(stdPath) || systemTempRoots.contains(resolvedPath)
    }

    static func fileInode(for url: URL) -> UInt64 {
        var st = stat()
        if stat(url.path, &st) == 0 {
            return UInt64(st.st_ino)
        }
        return 0
    }

    func watchFileDescriptorOnly(
        _ url: URL,
        onFileEvent: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) {
        lock.lock()
        let previousSource = fileWatchSource
        fileWatchSource = nil
        fileWatchDescriptor = -1
        lock.unlock()
        previousSource?.cancel()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let inode = Self.fileInode(for: url)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak source] in
            let flags = source?.data ?? []
            MainActor.assumeIsolated {
                onFileEvent(flags)
            }
        }
        source.setCancelHandler {
            close(fd)
        }

        lock.lock()
        fileWatchDescriptor = fd
        currentWatchedFileInode = inode
        fileWatchSource = source
        lock.unlock()
        source.resume()
    }

    func watchParentDirectoryOnly(
        _ parentURL: URL,
        onParentDirectoryEvent: @escaping @MainActor () -> Void
    ) {
        lock.lock()
        let previousSource = parentDirWatchSource
        parentDirWatchSource = nil
        parentDirWatchDescriptor = -1
        lock.unlock()
        previousSource?.cancel()

        guard !Self.isSystemTemporaryRootDirectory(parentURL) else { return }

        let dirFD = open(parentURL.path, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated {
                onParentDirectoryEvent()
            }
        }
        source.setCancelHandler {
            close(dirFD)
        }

        lock.lock()
        parentDirWatchDescriptor = dirFD
        parentDirWatchSource = source
        lock.unlock()
        source.resume()
    }

    func stopWatchingCurrentFile() {
        lock.lock()
        let fileSource = fileWatchSource
        let parentSource = parentDirWatchSource
        fileWatchSource = nil
        parentDirWatchSource = nil
        fileWatchDescriptor = -1
        parentDirWatchDescriptor = -1
        currentWatchedFileInode = 0
        lock.unlock()
        fileSource?.cancel()
        parentSource?.cancel()
    }

    @discardableResult
    func recordWatchedWorkspaceDirectory(
        _ url: URL,
        activeKeys: inout Set<String>,
        maxDirectories: Int,
        onDirectoryChanged: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !Self.isSystemTemporaryRootDirectory(url), !url.path.contains(".runfiles") else { return true }
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !activeKeys.contains(key) else { return true }
        let currentInode = Self.fileInode(for: url)
        guard currentInode != 0 else { return true }

        lock.lock()
        let atPerWatcherCapacity = !watchedDirectoryKeySet.contains(key) && watchedDirectoryKeySet.count >= maxDirectories
        lock.unlock()
        guard !atPerWatcherCapacity else { return false }

        let subscribed = directoryWatchHub.subscribe(
            watcherID: watcherID,
            key: key,
            url: url,
            currentInode: currentInode,
            onChanged: onDirectoryChanged,
            onInvalidated: { [weak self] in
                self?.handleInvalidatedDirectory(forKey: key)
            }
        )
        guard subscribed else { return false }

        lock.lock()
        watchedDirectoryKeySet.insert(key)
        lock.unlock()
        activeKeys.insert(key)
        return true
    }

    func releaseWatchedWorkspaceDirectory(forKey key: String) {
        lock.lock()
        let removed = watchedDirectoryKeySet.remove(key) != nil
        lock.unlock()
        if removed {
            directoryWatchHub.unsubscribe(watcherID: watcherID, keys: [key])
        }
    }

    private func handleInvalidatedDirectory(forKey key: String) {
        lock.lock()
        watchedDirectoryKeySet.remove(key)
        lock.unlock()
    }

    func pruneWatchedWorkspaceDirectories(keeping activeKeys: Set<String>) {
        lock.lock()
        let staleKeys = watchedDirectoryKeySet.filter { !activeKeys.contains($0) }
        for key in staleKeys {
            watchedDirectoryKeySet.remove(key)
        }
        lock.unlock()
        if !staleKeys.isEmpty {
            directoryWatchHub.unsubscribe(watcherID: watcherID, keys: staleKeys)
        }
    }

    func scheduleReload(after delay: TimeInterval = 0.02, _ action: @escaping @MainActor () -> Void) {
        lock.lock()
        pendingFolderWatchReloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearPendingReloadWorkItem()
            MainActor.assumeIsolated {
                action()
            }
        }
        pendingFolderWatchReloadWorkItem = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancelPendingReload() {
        lock.lock()
        let pendingWork = pendingFolderWatchReloadWorkItem
        pendingFolderWatchReloadWorkItem = nil
        lock.unlock()
        pendingWork?.cancel()
    }

    private func clearPendingReloadWorkItem() {
        lock.lock()
        pendingFolderWatchReloadWorkItem = nil
        lock.unlock()
    }

    func stopWatchingWorkspaceFolders() {
        lock.lock()
        let pendingWork = pendingFolderWatchReloadWorkItem
        pendingFolderWatchReloadWorkItem = nil
        let keys = Array(watchedDirectoryKeySet)
        watchedDirectoryKeySet.removeAll()
        lock.unlock()
        pendingWork?.cancel()
        if !keys.isEmpty {
            directoryWatchHub.unsubscribe(watcherID: watcherID, keys: keys)
        }
    }

    func stopAll() {
        stopWatchingCurrentFile()
        stopWatchingWorkspaceFolders()
    }
}
