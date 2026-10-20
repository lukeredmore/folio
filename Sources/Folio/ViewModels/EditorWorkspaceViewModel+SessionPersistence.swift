import AppKit
import Combine
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    func restoreStateOnInit(
        resolvedDefaults: UserDefaults,
        manager: RemoteWorkspaceManager
    ) {
        let loadedCustomThemes: [EditorTheme]
        if let customData = resolvedDefaults.data(forKey: Self.customThemesDefaultsKey),
           let decodedCustom = try? JSONDecoder().decode([EditorTheme].self, from: customData) {
            loadedCustomThemes = decodedCustom
        } else {
            loadedCustomThemes = []
        }
        self.customThemes = loadedCustomThemes

        let allAvailable = Self.mergeAvailableThemes(customThemes: loadedCustomThemes)
        var restoredTheme: EditorTheme
        if let activeData = resolvedDefaults.data(forKey: Self.activeThemeDataDefaultsKey),
           let decodedActive = try? JSONDecoder().decode(EditorTheme.self, from: activeData) {
            restoredTheme = decodedActive
        } else if let rawTheme = resolvedDefaults.string(forKey: Self.themeDefaultsKey),
                  let matched = allAvailable.first(where: {
                      $0.id.caseInsensitiveCompare(rawTheme) == .orderedSame ||
                      $0.name.caseInsensitiveCompare(rawTheme) == .orderedSame
                  }) ?? EditorTheme(rawValue: rawTheme) {
            restoredTheme = matched
            if let data = resolvedDefaults.data(forKey: Self.typographyDefaultsKey),
               let decodedTypo = try? JSONDecoder().decode(EditorTypographySettings.self, from: data) {
                restoredTheme.typography = decodedTypo
            }
        } else {
            restoredTheme = .daylight
            if let data = resolvedDefaults.data(forKey: Self.typographyDefaultsKey),
               let decodedTypo = try? JSONDecoder().decode(EditorTypographySettings.self, from: data) {
                restoredTheme.typography = decodedTypo
            }
        }

        self.theme = restoredTheme
        self.typography = restoredTheme.typography

        self.sourceCodeMode = resolvedDefaults.bool(forKey: Self.sourceCodeModeDefaultsKey)
        self.focusMode = resolvedDefaults.bool(forKey: Self.focusModeDefaultsKey)
        self.typewriterMode = resolvedDefaults.bool(forKey: Self.typewriterModeDefaultsKey)
        self.spellCheckEnabled = resolvedDefaults.bool(forKey: Self.spellCheckEnabledDefaultsKey)
        if resolvedDefaults.object(forKey: Self.sourceLineWidthDefaultsKey) != nil {
            self.sourceLineWidth = max(0, resolvedDefaults.integer(forKey: Self.sourceLineWidthDefaultsKey))
        } else {
            self.sourceLineWidth = MarkdownSourceReflow.defaultWidth
        }

        if resolvedDefaults.object(forKey: Self.showSidebarDefaultsKey) != nil {
            self.showSidebar = resolvedDefaults.bool(forKey: Self.showSidebarDefaultsKey)
        } else {
            self.showSidebar = true
        }

        if let rawTab = resolvedDefaults.string(forKey: Self.activeSidebarTabDefaultsKey),
           let decodedTab = SidebarTab(rawValue: rawTab) {
            self.activeSidebarTab = decodedTab
        } else {
            self.activeSidebarTab = .outline
        }

        if let rawStyle = resolvedDefaults.string(forKey: Self.fileDisplayStyleDefaultsKey),
           let decodedStyle = FileDisplayStyle(rawValue: rawStyle) {
            self.fileDisplayStyle = decodedStyle
        } else {
            self.fileDisplayStyle = .tree
        }

        if let rawOrder = resolvedDefaults.string(forKey: Self.fileSortOrderDefaultsKey),
           let decodedOrder = FileSortOrder(rawValue: rawOrder) {
            self.fileSortOrder = decodedOrder
        } else {
            self.fileSortOrder = .name
        }

        if let savedCollapsed = resolvedDefaults.stringArray(forKey: Self.collapsedDirectoryPathsDefaultsKey) {
            self.collapsedDirectoryPaths = Set(savedCollapsed)
        } else {
            self.collapsedDirectoryPaths = []
        }

        if let savedTimelinesData = resolvedDefaults.data(forKey: Self.undoTimelinesDefaultsKey),
           let decodedTimelines = try? JSONDecoder().decode([String: DocumentUndoTimeline].self, from: savedTimelinesData) {
            self.perFileUndoTimelines = decodedTimelines
        } else {
            self.perFileUndoTimelines = [:]
        }

        if let savedRecentPaths = resolvedDefaults.stringArray(forKey: Self.recentFilePathsDefaultsKey) {
            let fm = FileManager.default
            self.recentFileURLs = savedRecentPaths.compactMap { path in
                var isDir: ObjCBool = false
                guard !path.isEmpty,
                      fm.fileExists(atPath: path, isDirectory: &isDir),
                      !isDir.boolValue else {
                    return nil
                }
                return URL(fileURLWithPath: path)
            }
        } else {
            self.recentFileURLs = []
        }

        // Restore open file / buffer session if available
        let restoredFileURL = Self.resolvePersistedURL(
            from: resolvedDefaults,
            pathKey: Self.currentFilePathDefaultsKey,
            bookmarkKey: Self.currentFileBookmarkDefaultsKey,
            requireDirectory: false
        )
        let hasSavedSession = resolvedDefaults.bool(forKey: Self.hasSavedDocumentSessionDefaultsKey)
        let savedIsDirty = resolvedDefaults.bool(forKey: Self.unsavedBufferIsDirtyDefaultsKey)
        let savedBufferText = resolvedDefaults.string(forKey: Self.unsavedBufferTextDefaultsKey)
        let hadSavedFilePath = (resolvedDefaults.string(forKey: Self.currentFilePathDefaultsKey) != nil)

        let initialContent: String
        let initialFileURL: URL?
        let initialIsDirty: Bool

        if let fileURL = restoredFileURL {
            if savedIsDirty, let unsavedText = savedBufferText {
                initialFileURL = fileURL
                initialContent = unsavedText
                initialIsDirty = true
            } else if let diskContent = try? String(contentsOf: fileURL, encoding: .utf8) {
                initialFileURL = fileURL
                initialContent = diskContent
                initialIsDirty = false
            } else {
                initialFileURL = nil
                initialContent = Self.defaultWelcomeDocument
                initialIsDirty = false
            }
        } else if savedIsDirty, let unsavedText = savedBufferText {
            initialFileURL = nil
            initialContent = unsavedText
            initialIsDirty = true
        } else if hasSavedSession, !hadSavedFilePath, let untitledText = savedBufferText {
            initialFileURL = nil
            initialContent = untitledText
            initialIsDirty = false
        } else {
            initialFileURL = nil
            initialContent = Self.defaultWelcomeDocument
            initialIsDirty = false
        }

        self.currentFileURL = initialFileURL
        self.markdownText = initialContent
        self.lastSavedDiskContent = initialFileURL != nil ? ((try? String(contentsOf: initialFileURL!, encoding: .utf8)) ?? initialContent) : initialContent
        self.isDirty = initialIsDirty
        self.stats = DocumentStats.compute(for: initialContent)

        let analysis = MarkdownLiveStyler.applyStyles(
            to: NSTextStorage(string: initialContent),
            theme: self.theme,
            typography: self.typography,
            sourceCodeMode: self.sourceCodeMode,
            focusMode: self.focusMode,
            selectedRange: NSRange(location: 0, length: 0)
        )
        self.headings = analysis.headings

        if (initialFileURL != nil || initialIsDirty || (hasSavedSession && !hadSavedFilePath)),
           resolvedDefaults.object(forKey: Self.selectedCursorLocationDefaultsKey) != nil {
            let savedLoc = resolvedDefaults.integer(forKey: Self.selectedCursorLocationDefaultsKey)
            let maxLen = (initialContent as NSString).length
            if savedLoc >= 0 && savedLoc <= maxLen {
                self.currentSelectedRange = NSRange(location: savedLoc, length: 0)
                if savedLoc > 0 {
                    self.pendingScrollToCharacterLocation = savedLoc
                }
            }
        }

        let initialWorkspaceURL: URL
        if let savedWorkspaceURL = Self.resolvePersistedURL(
            from: resolvedDefaults,
            pathKey: Self.workspaceFolderPathDefaultsKey,
            bookmarkKey: Self.workspaceFolderBookmarkDefaultsKey,
            requireDirectory: true
        ) {
            initialWorkspaceURL = savedWorkspaceURL
        } else {
            initialWorkspaceURL = Self.defaultFallbackWorkspaceFolderURL()
        }

        manager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        manager.onMirrorUpdated = { [weak self] _, updatedURLs in
            guard let self = self else { return }
            self.reloadWorkspaceTree()
            if let currentURL = self.currentFileURL?.standardizedFileURL,
               updatedURLs.contains(currentURL) {
                self.checkForExternalFileChanges(sourceDescription: "SSH Remote")
            }
        }

        self.workspaceFolderURL = initialWorkspaceURL
        self.reloadWorkspaceTree()
        if let fileURL = initialFileURL {
            self.watchCurrentFile(fileURL)
        }
        self.refreshUndoRedoAvailability()
        self.isRestoringState = false
    }

    static func defaultFallbackWorkspaceFolderURL() -> URL {
        let cwdPath = FileManager.default.currentDirectoryPath
        if cwdPath == "/" || cwdPath.isEmpty {
            let bundleURL = Bundle.main.bundleURL
            if bundleURL.pathExtension == "app" {
                let parentDir = bundleURL.deletingLastPathComponent()
                if parentDir.path != "/" && parentDir.path != "/Applications" {
                    return parentDir
                } else {
                    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                        ?? FileManager.default.homeDirectoryForCurrentUser
                }
            } else {
                return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
            }
        } else {
            return URL(fileURLWithPath: cwdPath, isDirectory: true)
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
