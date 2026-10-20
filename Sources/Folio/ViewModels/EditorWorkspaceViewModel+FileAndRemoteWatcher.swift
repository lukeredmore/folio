import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension EditorWorkspaceViewModel {

    // MARK: - File & Workspace Operations
    public func newDocument() {
        flushPendingAutoSaveBeforeSwitchingFile()
        stopWatchingCurrentFile()
        activeConflict = nil
        dismissExternalUpdateNotice()
        isApplyingInternalStateChange = true
        currentFileURL = nil
        markdownText = "# Untitled\n\n"
        lastSavedDiskContent = "# Untitled\n\n"
        isDirty = false
        currentSelectedRange = NSRange(location: 0, length: 0)
        isApplyingInternalStateChange = false
        userDefaults.set(0, forKey: Self.selectedCursorLocationDefaultsKey)
        stats = DocumentStats.compute(for: markdownText)
        if activeTextView == nil {
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: markdownText),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: NSRange(location: 0, length: 0)
            )
            headings = analysis.headings
        }
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
        panel.prompt = "Open Folder"
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
        flushPendingAutoSaveBeforeSwitchingFile()
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            activeConflict = nil
            dismissExternalUpdateNotice()
            recentSelfWrites.removeAll()
            isApplyingInternalStateChange = true
            currentFileURL = url
            markdownText = content
            lastSavedDiskContent = content
            isDirty = false
            currentSelectedRange = NSRange(location: 0, length: 0)
            isApplyingInternalStateChange = false
            userDefaults.set(0, forKey: Self.selectedCursorLocationDefaultsKey)
            stats = DocumentStats.compute(for: content)
            if activeTextView == nil {
                let analysis = MarkdownLiveStyler.applyStyles(
                    to: NSTextStorage(string: content),
                    theme: theme,
                    typography: typography,
                    sourceCodeMode: sourceCodeMode,
                    focusMode: focusMode,
                    selectedRange: NSRange(location: 0, length: 0)
                )
                headings = analysis.headings
            }
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
            writeDocument(to: url)
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
    }

    func writeDocument(to url: URL) {
        performDiskWrite(markdownText, to: url)
        persistDocumentSessionState()
    }

    // MARK: - Remote Mount Operations

    @discardableResult
    public func addRemoteMount(_ spec: RemoteMountSpec) async -> Bool {
        remoteConnectionBannerDismissed = false
        let ok = await remoteWorkspaceManager.addMount(spec)
        reloadWorkspaceTree()
        showSidebar = true
        activeSidebarTab = .files

        // If the user mounted a single remote file, open it immediately once mirrored
        if spec.targetKind == .file {
            let filename = (spec.remotePath as NSString).lastPathComponent
            let mirroredURL = remoteWorkspaceManager.localFileURL(for: filename, in: spec)
            if FileManager.default.fileExists(atPath: mirroredURL.path) {
                openFile(at: mirroredURL)
            }
        }
        return ok
    }

    @discardableResult
    public func connectRemoteMount(_ spec: RemoteMountSpec) async -> Bool {
        await addRemoteMount(spec)
    }

    public func removeRemoteMount(id: UUID) {
        remoteWorkspaceManager.removeMount(id: id)
        reloadWorkspaceTree()
    }

    public func disconnectRemoteMount(id: UUID) {
        removeRemoteMount(id: id)
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

    // MARK: - POSIX DispatchSource File & Parent Directory Watcher

    nonisolated static func fileInode(for url: URL) -> UInt64 {
        var st = stat()
        if stat(url.path, &st) == 0 {
            return UInt64(st.st_ino)
        }
        return 0
    }

    func watchCurrentFile(_ url: URL) {
        stopWatchingCurrentFile()
        watchFileDescriptorOnly(url)
        watchParentDirectoryOnly(url.deletingLastPathComponent())
    }

    func watchFileDescriptorOnly(_ url: URL) {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        fileWatchDescriptor = -1

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileWatchDescriptor = fd
        watchedFileInode = Self.fileInode(for: url)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .link, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            let flags = source?.data ?? []
            MainActor.assumeIsolated {
                guard let self = self, self.currentFileURL != nil else { return }
                self.checkForExternalFileChanges()
                if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) || flags.contains(.link) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                        guard let self = self, let activeURL = self.currentFileURL else { return }
                        self.watchFileDescriptorOnly(activeURL)
                        self.checkForExternalFileChanges()
                    }
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatchSource = source
    }

    func watchParentDirectoryOnly(_ parentURL: URL) {
        parentDirWatchSource?.cancel()
        parentDirWatchSource = nil
        parentDirWatchDescriptor = -1

        let dirFD = open(parentURL.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        parentDirWatchDescriptor = dirFD

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.checkForExternalFileChanges()
            }
        }
        source.setCancelHandler {
            close(dirFD)
        }
        source.resume()
        parentDirWatchSource = source
    }

    nonisolated func stopWatchingCurrentFile() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        fileWatchDescriptor = -1
        parentDirWatchSource?.cancel()
        parentDirWatchSource = nil
        parentDirWatchDescriptor = -1
        watchedFileInode = 0
    }
}
