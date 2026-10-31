import AppKit
import Foundation

extension EditorWorkspaceViewModel {

    // MARK: - Sidebar Deletion

    /// Moves a local item to the Trash, or permanently deletes a remote file after confirmation.
    public func requestDeleteWorkspaceItem(at url: URL) {
        let isRemote = remoteWorkspaceManager.isRemoteURL(url)
        if isRemote && !confirmPermanentRemoteDelete(of: url) { return }
        releaseCurrentFileIfDeleting(url)
        if isRemote {
            Task { @MainActor in
                do {
                    try await remoteWorkspaceManager.deleteRemoteFile(at: url)
                } catch {
                    NSSound.beep()
                }
                reloadWorkspaceTree()
            }
            return
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            trashCompanionComments(for: url)
        } catch {
            NSSound.beep()
        }
        reloadWorkspaceTree()
    }

    private func confirmPermanentRemoteDelete(of url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete “\(url.lastPathComponent)” from the remote host?"
        alert.informativeText = "Remote files do not go to the Trash. You cannot undo this action."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func trashCompanionComments(for url: URL) {
        let fm = FileManager.default
        for companion in SelectionComment.candidateCompanionURLs(for: url) where fm.fileExists(atPath: companion.path) {
            try? fm.trashItem(at: companion, resultingItemURL: nil)
        }
    }

    /// Closes the open document without writing it back when it is the deleted item or inside it.
    private func releaseCurrentFileIfDeleting(_ url: URL) {
        let target = url.standardizedFileURL.path
        if let pending = untouchedNewFile, Self.path(pending.url.standardizedFileURL.path, isWithin: target) {
            untouchedNewFile = nil
        }
        guard let current = currentFileURL, Self.path(current.standardizedFileURL.path, isWithin: target) else { return }
        pendingAutoSaveWorkItem?.cancel()
        pendingAutoSaveWorkItem = nil
        lastSavedDiskContent = markdownText
        newDocument()
    }

    static func path(_ path: String, isWithin root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - Untouched New Files

    /// Deletes the file made by New File if it still holds only its template.
    func discardUntouchedNewFile() {
        guard let pending = untouchedNewFile else { return }
        untouchedNewFile = nil
        let url = pending.url
        let isCurrent = currentFileURL?.standardizedFileURL == url.standardizedFileURL
        let content = isCurrent ? markdownText : (try? String(contentsOf: url, encoding: .utf8))
        guard content == pending.template, FileManager.default.fileExists(atPath: url.path) else { return }

        if remoteWorkspaceManager.isRemoteURL(url) {
            Task { @MainActor in
                try? await remoteWorkspaceManager.deleteRemoteFile(at: url)
                reloadWorkspaceTree()
            }
        } else {
            try? FileManager.default.removeItem(at: url)
            reloadWorkspaceTree()
        }
    }
}

extension WorkspaceFileNode {
    /// Local files and folders, and remote files (not remote folders or sidebar roots), can be deleted from the sidebar.
    var isDeletableFromSidebar: Bool {
        !isSidebarRoot && (!isRemote || !isDirectory)
    }
}
