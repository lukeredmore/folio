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
            isDirty = markdownText != lastSavedDiskContent
        }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingAutoSaveWorkItem = nil
                self.autoSaveOrStageCurrentDocument()
            }
        }
        pendingAutoSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoSaveDelay, execute: workItem)
    }

    /// Runs a scheduled autosave now. Called before switching files, saving, and quitting.
    public func flushPendingAutoSave() {
        guard let workItem = pendingAutoSaveWorkItem else { return }
        workItem.cancel()
        pendingAutoSaveWorkItem = nil
        autoSaveOrStageCurrentDocument()
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
            MainActor.assumeIsolated { self?.flushPendingAutoSave() }
        }
    }
}
