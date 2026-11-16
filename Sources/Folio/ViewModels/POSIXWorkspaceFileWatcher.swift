import Darwin
import Foundation

private struct WatchedDirectoryEntry {
    let source: DispatchSourceFileSystemObject
    let descriptor: Int32
    let inode: UInt64
}

final class POSIXWorkspaceFileWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var parentDirWatchSource: DispatchSourceFileSystemObject?
    private var fileWatchDescriptor: Int32 = -1
    private var parentDirWatchDescriptor: Int32 = -1
    private var currentWatchedFileInode: UInt64 = 0
    private var folderWatchEntries: [String: WatchedDirectoryEntry] = [:]
    private var pendingFolderWatchReloadWorkItem: DispatchWorkItem?

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
        return Set(folderWatchEntries.keys)
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

    func recordWatchedWorkspaceDirectory(
        _ url: URL,
        activeKeys: inout Set<String>,
        maxDirectories: Int,
        onDirectoryChanged: @escaping @MainActor () -> Void
    ) {
        guard !Self.isSystemTemporaryRootDirectory(url), !url.path.contains(".runfiles") else { return }
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !activeKeys.contains(key) else { return }
        let currentInode = Self.fileInode(for: url)
        guard currentInode != 0 else { return }

        var staleSource: DispatchSourceFileSystemObject?
        lock.lock()
        if let existing = folderWatchEntries[key] {
            if existing.inode == currentInode {
                lock.unlock()
                activeKeys.insert(key)
                return
            }
            staleSource = existing.source
            folderWatchEntries.removeValue(forKey: key)
        }
        let atCapacity = folderWatchEntries.count >= maxDirectories
        lock.unlock()
        staleSource?.cancel()
        guard !atCapacity else { return }

        let dirFD = open(url.path, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .extend, .attrib, .delete, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let flags = source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self?.removeWatchedDirectory(forKey: key)
            }
            MainActor.assumeIsolated {
                onDirectoryChanged()
            }
        }
        source.setCancelHandler {
            close(dirFD)
        }

        lock.lock()
        folderWatchEntries[key] = WatchedDirectoryEntry(source: source, descriptor: dirFD, inode: currentInode)
        lock.unlock()
        source.resume()
        activeKeys.insert(key)
    }

    private func removeWatchedDirectory(forKey key: String) {
        lock.lock()
        let removed = folderWatchEntries.removeValue(forKey: key)
        lock.unlock()
        removed?.source.cancel()
    }

    func pruneWatchedWorkspaceDirectories(keeping activeKeys: Set<String>) {
        lock.lock()
        let staleKeys = folderWatchEntries.keys.filter { !activeKeys.contains($0) }
        var removedSources: [DispatchSourceFileSystemObject] = []
        for key in staleKeys {
            if let entry = folderWatchEntries.removeValue(forKey: key) {
                removedSources.append(entry.source)
            }
        }
        lock.unlock()
        for source in removedSources {
            source.cancel()
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
        let entries = Array(folderWatchEntries.values)
        folderWatchEntries.removeAll()
        lock.unlock()
        pendingWork?.cancel()
        for entry in entries {
            entry.source.cancel()
        }
    }

    func stopAll() {
        stopWatchingCurrentFile()
        stopWatchingWorkspaceFolders()
    }
}
