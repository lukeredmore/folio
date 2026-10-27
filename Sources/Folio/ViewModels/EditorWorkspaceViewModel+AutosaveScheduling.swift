import AppKit
import CryptoKit
import Foundation

/// Digests of recent self-written file contents, used to recognize file-watcher echoes of our
/// own writes. Stores fixed-size SHA-256 digests instead of full copies of the document.
struct SelfWriteHistory {
    private var digests: [SHA256.Digest] = []
    let capacity: Int

    init(capacity: Int = 32) {
        self.capacity = capacity
    }

    mutating func record(_ content: String) {
        digests.append(SHA256.hash(data: Data(content.utf8)))
        if digests.count > capacity {
            digests.removeFirst(digests.count - capacity)
        }
    }

    func contains(_ content: String) -> Bool {
        guard !digests.isEmpty else { return false }
        return digests.contains(SHA256.hash(data: Data(content.utf8)))
    }

    mutating func removeAll() {
        digests.removeAll()
    }

    var count: Int { digests.count }
}

extension EditorWorkspaceViewModel {

    /// Autosaves after `autoSaveDelay` seconds without further edits, so typing does not read,
    /// compare, and rewrite the whole file (and upload it for remote files) on every keystroke.
    /// A delay of 0 saves immediately.
    func scheduleAutoSave() {
        pendingAutoSaveWorkItem?.cancel()
        pendingAutoSaveWorkItem = nil
        guard autoSaveDelay > 0 else {
            autoSaveOrStageCurrentDocument()
            return
        }
        if currentFileURL != nil {
            let dirty = markdownText != lastSavedDiskContent
            if isDirty != dirty {
                isDirty = dirty
            }
        }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingAutoSaveWorkItem = nil
                self.persistUndoTimelines()
                self.autoSaveOrStageCurrentDocument()
            }
        }
        pendingAutoSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoSaveDelay, execute: workItem)
    }

    /// Runs a scheduled autosave now. Called before switching files, saving, and quitting.
    public func flushPendingAutoSave() {
        if let workItem = pendingAutoSaveWorkItem {
            workItem.cancel()
            pendingAutoSaveWorkItem = nil
            autoSaveOrStageCurrentDocument()
        }
        if hasUnpersistedUndoChanges {
            persistUndoTimelines()
        }
    }

    var hasPendingAutoSave: Bool { pendingAutoSaveWorkItem != nil }

    /// Uploads `content` for a remote file. At most one upload per file is in flight, and when it
    /// finishes only the newest queued content is uploaded, so uploads never overlap or arrive
    /// out of order.
    func enqueueRemoteUpload(_ content: String, to url: URL) {
        let key = url.standardizedFileURL
        pendingRemoteUploads[key] = content
        guard !remoteUploadsInFlight.contains(key) else { return }
        remoteUploadsInFlight.insert(key)
        Task { @MainActor in
            while let next = self.pendingRemoteUploads.removeValue(forKey: key) {
                await self.remoteWorkspaceManager.saveRemoteFile(at: url, content: next)
            }
            self.remoteUploadsInFlight.remove(key)
        }
    }

    func observeTerminationForPendingAutoSave() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingAutoSave()
                self?.discardUntouchedNewFile()
            }
        }
    }

    static func resolvePersistedURL(
        from defaults: UserDefaults,
        pathKey: String,
        bookmarkKey: String,
        requireDirectory: Bool
    ) -> URL? {
        let fm = FileManager.default
        if let savedPath = defaults.string(forKey: pathKey), !savedPath.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: savedPath, isDirectory: &isDir),
               isDir.boolValue == requireDirectory {
                if let bookmarkData = defaults.data(forKey: bookmarkKey) {
                    var isStale = false
                    if let bookmarkedURL = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: [.withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ) {
                        _ = bookmarkedURL.startAccessingSecurityScopedResource()
                    }
                }
                return URL(fileURLWithPath: savedPath, isDirectory: requireDirectory)
            }
        }

        if let bookmarkData = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let bookmarkedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: bookmarkedURL.path, isDirectory: &isDir),
                   isDir.boolValue == requireDirectory {
                    _ = bookmarkedURL.startAccessingSecurityScopedResource()
                    if isStale,
                       let freshData = try? bookmarkedURL.bookmarkData(
                           options: [],
                           includingResourceValuesForKeys: nil,
                           relativeTo: nil
                       ) {
                        defaults.set(freshData, forKey: bookmarkKey)
                    }
                    defaults.set(bookmarkedURL.path, forKey: pathKey)
                    return bookmarkedURL
                }
            }
        }

        return nil
    }

    func persistWorkspaceFolder(_ folderURL: URL?) {
        guard !isRestoringState else { return }
        if let folderURL {
            userDefaults.set(folderURL.path, forKey: Self.workspaceFolderPathDefaultsKey)
            if let bookmark = try? folderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                userDefaults.set(bookmark, forKey: Self.workspaceFolderBookmarkDefaultsKey)
            }
        } else {
            userDefaults.removeObject(forKey: Self.workspaceFolderPathDefaultsKey)
            userDefaults.removeObject(forKey: Self.workspaceFolderBookmarkDefaultsKey)
        }
    }

    func persistCurrentFileBookmark() {
        guard !isRestoringState else { return }
        if let fileURL = currentFileURL {
            userDefaults.set(fileURL.path, forKey: Self.currentFilePathDefaultsKey)
            if let bookmark = try? fileURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                userDefaults.set(bookmark, forKey: Self.currentFileBookmarkDefaultsKey)
            }
        } else {
            userDefaults.removeObject(forKey: Self.currentFilePathDefaultsKey)
            userDefaults.removeObject(forKey: Self.currentFileBookmarkDefaultsKey)
        }
    }

    func persistDocumentSessionState() {
        guard !isRestoringState else { return }
        userDefaults.set(true, forKey: Self.hasSavedDocumentSessionDefaultsKey)
        userDefaults.set(isDirty, forKey: Self.unsavedBufferIsDirtyDefaultsKey)
        userDefaults.set(currentSelectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        if hasUnpersistedUndoChanges {
            persistUndoTimelines()
        }
        if let fileURL = currentFileURL {
            userDefaults.set(fileURL.path, forKey: Self.currentFilePathDefaultsKey)
            if isDirty {
                userDefaults.set(markdownText, forKey: Self.unsavedBufferTextDefaultsKey)
            } else {
                userDefaults.removeObject(forKey: Self.unsavedBufferTextDefaultsKey)
            }
        } else {
            userDefaults.removeObject(forKey: Self.currentFilePathDefaultsKey)
            userDefaults.removeObject(forKey: Self.currentFileBookmarkDefaultsKey)
            userDefaults.set(markdownText, forKey: Self.unsavedBufferTextDefaultsKey)
        }
    }
}
