import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension EditorWorkspaceViewModel {

    // MARK: - File & Workspace Operations
    public func newDocument() {
        guard flushPendingAutoSaveBeforeSwitchingFile() else { return }
        discardUntouchedNewFile()
        stopWatchingCurrentFile()
        activeConflict = nil
        dismissExternalUpdateNotice()
        clearAllSelectionComments(deleteCompanionFile: false)
        isApplyingInternalStateChange = true
        currentFileURL = nil
        lastSavedDiskContent = Self.untitledDocumentTemplate
        isDirty = false
        pendingScrollToCharacterLocation = nil
        isApplyingInternalStateChange = false
        applyProgrammaticBufferState(
            Self.untitledDocumentTemplate,
            selectedRange: NSRange(location: 0, length: 0),
            reconcileComments: false
        )
        setSessionValue(0, forKey: Self.selectedCursorLocationDefaultsKey)
        refreshUndoRedoAvailability()
        persistDocumentSessionState()
    }

    public func openDocumentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspaceFolderURL ?? currentFileURL?.deletingLastPathComponent()
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                loadWorkspaceFolder(url)
                showSidebar = true
                activeSidebarTab = .files
            } else {
                openFile(at: url)
            }
        }
    }

    public func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspaceFolderURL ?? currentFileURL?.deletingLastPathComponent()
        panel.prompt = "Add Folder"
        if panel.runModal() == .OK, let url = panel.url {
            loadWorkspaceFolder(url)
            showSidebar = true
            activeSidebarTab = .files
        }
    }

    public func openFolder(at url: URL) {
        loadWorkspaceFolder(url)
    }

    public func openFile(at url: URL) {
        if currentFileURL?.standardizedFileURL != url.standardizedFileURL {
            guard flushPendingAutoSaveBeforeSwitchingFile() else { return }
            discardUntouchedNewFile()
        } else {
            pendingAutoSaveWorkItem?.cancel()
            pendingAutoSaveWorkItem = nil
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            activeConflict = nil
            dismissExternalUpdateNotice()
            clearAllSelectionComments(deleteCompanionFile: false)
            recentSelfWrites.removeAll()
            isApplyingInternalStateChange = true
            currentFileURL = url
            lastSavedDiskContent = content
            isDirty = false
            pendingScrollToCharacterLocation = nil
            isApplyingInternalStateChange = false
            applyProgrammaticBufferState(
                content,
                selectedRange: NSRange(location: 0, length: 0),
                reconcileComments: false
            )
            loadCompanionComments(for: url, documentText: content)
            setSessionValue(0, forKey: Self.selectedCursorLocationDefaultsKey)
            addRecentFile(url)
            watchCurrentFile(url)
            refreshUndoRedoAvailability()
            persistDocumentSessionState()
        } catch {
            NSSound.beep()
        }
    }

    public func saveDocument() {
        pendingAutoSaveWorkItem?.cancel()
        pendingAutoSaveWorkItem = nil
        if let url = currentFileURL {
            writeDocument(to: url)
        } else {
            saveDocumentAs()
        }
    }

    public func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentTitle
        panel.directoryURL = workspaceFolderURL ?? currentFileURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            guard writeDocument(to: url) else { return }
            currentFileURL = url
            addRecentFile(url)
            watchCurrentFile(url)
            if let folder = workspaceFolderURL {
                loadWorkspaceFolder(folder)
            }
        }
    }

    public func createNewFileInWorkspace(in targetDirectoryURL: URL? = nil) {
        let baseFolder = targetDirectoryURL ?? workspaceFolderURL
        guard let folder = baseFolder else {
            newDocument()
            return
        }
        var candidateIndex = 1
        var targetURL = folder.appendingPathComponent("Untitled.md")
        while FileManager.default.fileExists(atPath: targetURL.path) {
            candidateIndex += 1
            targetURL = folder.appendingPathComponent("Untitled \(candidateIndex).md")
        }
        let template = "# \(targetURL.deletingPathExtension().lastPathComponent)\n\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? template.write(to: targetURL, atomically: true, encoding: .utf8)

        if remoteWorkspaceManager.isRemoteURL(targetURL) {
            Task { @MainActor in
                await remoteWorkspaceManager.saveRemoteFile(at: targetURL, content: template)
            }
        }
        reloadWorkspaceTree()
        openFile(at: targetURL)
        untouchedNewFile = (targetURL, template)
    }

    @discardableResult
    func writeDocument(to url: URL) -> Bool {
        let wrote = performDiskWrite(markdownText, to: url)
        if wrote {
            saveCompanionCommentsToDisk(for: url)
        }
        persistDocumentSessionState()
        return wrote
    }

    // MARK: - Remote Mount Operations

    @discardableResult
    public func connectRemoteMount(_ spec: RemoteMountSpec) async -> Bool {
        remoteConnectionBannerDismissed = false
        let ok = await remoteWorkspaceManager.addMount(spec)
        reloadWorkspaceTree()
        showSidebar = true
        activeSidebarTab = .files

        if spec.targetKind == .file {
            let filename = (spec.remotePath as NSString).lastPathComponent
            let mirroredURL = remoteWorkspaceManager.localFileURL(for: filename, in: spec)
            if FileManager.default.fileExists(atPath: mirroredURL.path) {
                openFile(at: mirroredURL)
            }
        }
        return ok
    }

    public func disconnectRemoteMount(id: UUID) {
        remoteWorkspaceManager.removeMount(id: id)
        reloadWorkspaceTree()
    }

    public func syncRemoteMountNow(id: UUID) {
        remoteConnectionBannerDismissed = false
        Task { @MainActor in
            _ = await remoteWorkspaceManager.syncMount(id: id, isManualRetry: true)
            reloadWorkspaceTree()
        }
    }

    public func clearRecentFiles() {
        recentFileURLs.removeAll()
    }

    func addRecentFile(_ url: URL) {
        recentFileURLs.removeAll(where: { $0.standardizedFileURL == url.standardizedFileURL })
        recentFileURLs.insert(url, at: 0)
        if recentFileURLs.count > 15 {
            recentFileURLs = Array(recentFileURLs.prefix(15))
        }
    }

    // MARK: - POSIX DispatchSource File & Workspace Folder Watcher

    public nonisolated static func isSystemTemporaryRootDirectory(_ url: URL) -> Bool {
        POSIXWorkspaceFileWatcher.isSystemTemporaryRootDirectory(url)
    }

    nonisolated static func fileInode(for url: URL) -> UInt64 {
        POSIXWorkspaceFileWatcher.fileInode(for: url)
    }

    func watchCurrentFile(_ url: URL) {
        stopWatchingCurrentFile()
        watchFileDescriptorOnly(url)
        watchParentDirectoryOnly(url.deletingLastPathComponent())
    }

    func watchFileDescriptorOnly(_ url: URL) {
        workspaceFileWatcher.watchFileDescriptorOnly(url) { [weak self] flags in
            guard let self, self.currentFileURL != nil else { return }
            self.checkForExternalFileChanges()
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) || flags.contains(.link) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    guard let self, let activeURL = self.currentFileURL else { return }
                    self.watchFileDescriptorOnly(activeURL)
                    self.checkForExternalFileChanges()
                }
            }
        }
    }

    func watchParentDirectoryOnly(_ parentURL: URL) {
        workspaceFileWatcher.watchParentDirectoryOnly(parentURL) { [weak self] in
            guard let self else { return }
            self.checkForExternalFileChanges()
            if let url = self.currentFileURL, self.isCurrentDocumentLaTeX {
                LaTeXProjectContext.scheduleRefresh(forFile: url)
            }
        }
    }

    nonisolated func stopWatchingCurrentFile() {
        workspaceFileWatcher.stopWatchingCurrentFile()
    }

    static let maxWatchedWorkspaceDirectories = 256

    func recordWatchedWorkspaceDirectory(_ url: URL, activeKeys: inout Set<String>) {
        workspaceFileWatcher.recordWatchedWorkspaceDirectory(
            url,
            activeKeys: &activeKeys,
            maxDirectories: Self.maxWatchedWorkspaceDirectories
        ) { [weak self] in
            self?.scheduleWorkspaceTreeReloadFromWatcher()
        }
    }

    func pruneWatchedWorkspaceDirectories(keeping activeKeys: Set<String>) {
        workspaceFileWatcher.pruneWatchedWorkspaceDirectories(keeping: activeKeys)
    }

    func scheduleWorkspaceTreeReloadFromWatcher() {
        workspaceFileWatcher.scheduleReload { [weak self] in
            guard let self else { return }
            self.reloadWorkspaceTree()
            if !self.workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.performWorkspaceSearch()
            }
        }
    }

    nonisolated func stopWatchingWorkspaceFolders() {
        workspaceFileWatcher.stopWatchingWorkspaceFolders()
    }
}
