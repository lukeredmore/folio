import AppKit
import Combine
import Foundation
import SwiftUI

public enum SidebarTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case outline = "Outline"
    case search = "Search"

    public var id: String { rawValue }
}

public enum FileDisplayStyle: String, CaseIterable {
    case tree = "Tree"
    case list = "List"
}

@MainActor
public final class EditorWorkspaceViewModel: ObservableObject {

    // MARK: - Document & Editor State
    @Published public var markdownText: String {
        didSet {
            guard !isRestoringState else { return }
            if !isApplyingInternalStateChange && markdownText != oldValue {
                let allowCoalesce = isLiveKeystrokeInProgress && canCoalesceLiveTyping
                recordUndoStep(
                    from: oldValue,
                    to: markdownText,
                    previousSelection: currentSelectedRange,
                    newSelection: currentSelectedRange,
                    origin: pendingEditOrigin,
                    summary: pendingEditSummary,
                    allowCoalescing: allowCoalesce
                )
                pendingEditOrigin = .userTyping
                pendingEditSummary = nil
                stats = DocumentStats.compute(for: markdownText, selectedRange: currentSelectedRange)
                if activeTextView == nil {
                    let analysis = MarkdownLiveStyler.applyStyles(
                        to: NSTextStorage(string: markdownText),
                        theme: theme,
                        typography: typography,
                        sourceCodeMode: sourceCodeMode,
                        focusMode: focusMode,
                        selectedRange: currentSelectedRange
                    )
                    headings = analysis.headings
                }
                autoSaveOrStageCurrentDocument()
            } else {
                persistDocumentSessionState()
            }
        }
    }
    @Published public var currentFileURL: URL? {
        didSet {
            guard !isRestoringState else { return }
            persistCurrentFileBookmark()
            persistDocumentSessionState()
            refreshUndoRedoAvailability()
        }
    }
    @Published public var isDirty: Bool = false {
        didSet {
            guard !isRestoringState else { return }
            persistDocumentSessionState()
        }
    }

    // MARK: - Autosave, Infinite Undo & External Update / Conflict State
    @Published public var autoSaveEnabled: Bool = true
    @Published public private(set) var lastAutoSavedAt: Date?
    @Published public private(set) var lastSavedDiskContent: String = ""
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false
    @Published public var externalUpdateNotice: ExternalUpdateNotice?
    @Published public var externalUpdateHighlightRanges: [NSRange] = []
    @Published public var showExternalUpdateDiffModal: Bool = false
    @Published public var activeConflict: DocumentConflict?
    @Published public var showConflictResolverModal: Bool = false

    private var perFileUndoTimelines: [String: DocumentUndoTimeline] = [:]
    public var currentSelectedRange: NSRange = NSRange(location: 0, length: 0)
    private var isApplyingInternalStateChange: Bool = false
    private var pendingEditOrigin: UndoEntryOrigin = .userTyping
    private var pendingEditSummary: String?
    private var canCoalesceLiveTyping: Bool = false
    public var isLiveKeystrokeInProgress: Bool = false
    private var recentSelfWrittenContents: [String] = []

    // MARK: - Editor Modes, Theme & Typography
    @Published public var theme: EditorTheme = .daylight {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(theme.rawValue, forKey: Self.themeDefaultsKey)
        }
    }
    @Published public var typography: EditorTypographySettings = .default {
        didSet {
            guard !isRestoringState else { return }
            if let encoded = try? JSONEncoder().encode(typography) {
                userDefaults.set(encoded, forKey: Self.typographyDefaultsKey)
            }
        }
    }
    @Published public var sourceCodeMode: Bool = false {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(sourceCodeMode, forKey: Self.sourceCodeModeDefaultsKey)
        }
    }
    @Published public var prettyModeEnabled: Bool = true
    @Published public var focusMode: Bool = false {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(focusMode, forKey: Self.focusModeDefaultsKey)
        }
    }
    @Published public var typewriterMode: Bool = false {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(typewriterMode, forKey: Self.typewriterModeDefaultsKey)
        }
    }
    @Published public var spellCheckEnabled: Bool = false {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(spellCheckEnabled, forKey: Self.spellCheckEnabledDefaultsKey)
        }
    }
    /// Column width that edited paragraphs are hard-wrapped to in the Markdown source (0 = off).
    @Published public var sourceLineWidth: Int = MarkdownSourceReflow.defaultWidth {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(sourceLineWidth, forKey: Self.sourceLineWidthDefaultsKey)
        }
    }

    // MARK: - Sidebar & Panels
    @Published public var showSidebar: Bool = true {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(showSidebar, forKey: Self.showSidebarDefaultsKey)
        }
    }
    @Published public var activeSidebarTab: SidebarTab = .outline {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(activeSidebarTab.rawValue, forKey: Self.activeSidebarTabDefaultsKey)
        }
    }
    @Published public var fileDisplayStyle: FileDisplayStyle = .tree {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(fileDisplayStyle.rawValue, forKey: Self.fileDisplayStyleDefaultsKey)
        }
    }
    @Published public var fileSortOrder: FileSortOrder = .name {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(fileSortOrder.rawValue, forKey: Self.fileSortOrderDefaultsKey)
        }
    }
    @Published public var collapsedDirectoryPaths: Set<String> = [] {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(Array(collapsedDirectoryPaths).sorted(), forKey: Self.collapsedDirectoryPathsDefaultsKey)
        }
    }
    @Published public var outlineFilterText: String = ""

    // MARK: - Modals & Banners
    @Published public var showQuickOpen: Bool = false
    @Published public var quickOpenQuery: String = ""
    @Published public var showWordCountPopover: Bool = false
    @Published public var showInsertTableSheet: Bool = false
    @Published public var showSettingsModal: Bool = false
    @Published public var showFindReplaceBar: Bool = false
    @Published public var showAddRemoteModal: Bool = false
    @Published public var findQuery: String = ""
    @Published public var replaceQuery: String = ""

    // MARK: - Outline & Statistics
    @Published public var headings: [OutlineHeading] = []
    @Published public var activeHeadingID: String?
    @Published public var stats: DocumentStats = DocumentStats()
    @Published public var pendingScrollToCharacterLocation: Int?

    // MARK: - Workspace Files & Search
    @Published public var workspaceFolderURL: URL? {
        didSet {
            guard !isRestoringState else { return }
            persistWorkspaceFolder(workspaceFolderURL)
        }
    }
    @Published public var rootFileNodes: [WorkspaceFileNode] = []
    @Published public var flatMarkdownFiles: [WorkspaceFileNode] = []
    @Published public var recentFileURLs: [URL] = [] {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(recentFileURLs.map(\.path), forKey: Self.recentFilePathsDefaultsKey)
        }
    }

    // MARK: - Remote Folders & Files (SSH / SFTP Multi-Root Sync)
    public let remoteWorkspaceManager: RemoteWorkspaceManager
    public let userDefaults: UserDefaults
    @Published public var remoteConnectionBannerDismissed: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    private var isRestoringState: Bool = true

    @Published public var workspaceSearchQuery: String = ""
    @Published public var searchCaseSensitive: Bool = false
    @Published public var searchWholeWord: Bool = false
    @Published public var searchUseRegex: Bool = false
    @Published public var workspaceSearchMatches: [WorkspaceSearchMatch] = []

    public weak var activeTextView: HybridMarkdownTextView?

    public static let typographyDefaultsKey = "Folio.EditorTypographySettings.v2"
    public static let workspaceFolderPathDefaultsKey = "Folio.WorkspaceFolderPath.v1"
    public static let workspaceFolderBookmarkDefaultsKey = "Folio.WorkspaceFolderBookmark.v1"
    public static let currentFilePathDefaultsKey = "Folio.CurrentFilePath.v1"
    public static let currentFileBookmarkDefaultsKey = "Folio.CurrentFileBookmark.v1"
    public static let unsavedBufferTextDefaultsKey = "Folio.UnsavedBufferText.v1"
    public static let unsavedBufferIsDirtyDefaultsKey = "Folio.UnsavedBufferIsDirty.v1"
    public static let hasSavedDocumentSessionDefaultsKey = "Folio.HasSavedDocumentSession.v1"
    public static let recentFilePathsDefaultsKey = "Folio.RecentFilePaths.v1"
    public static let themeDefaultsKey = "Folio.EditorTheme.v1"
    public static let sourceCodeModeDefaultsKey = "Folio.SourceCodeMode.v1"
    public static let focusModeDefaultsKey = "Folio.FocusMode.v1"
    public static let typewriterModeDefaultsKey = "Folio.TypewriterMode.v1"
    public static let spellCheckEnabledDefaultsKey = "Folio.SpellCheckEnabled.v1"
    public static let sourceLineWidthDefaultsKey = "Folio.SourceLineWidth.v1"
    public static let showSidebarDefaultsKey = "Folio.ShowSidebar.v1"
    public static let activeSidebarTabDefaultsKey = "Folio.ActiveSidebarTab.v1"
    public static let fileDisplayStyleDefaultsKey = "Folio.FileDisplayStyle.v1"
    public static let fileSortOrderDefaultsKey = "Folio.FileSortOrder.v1"
    public static let collapsedDirectoryPathsDefaultsKey = "Folio.CollapsedDirectoryPaths.v1"
    public static let selectedCursorLocationDefaultsKey = "Folio.SelectedCursorLocation.v1"
    public static let undoTimelinesDefaultsKey = "Folio.PerFileUndoTimelines.v1"

    nonisolated(unsafe) private var fileWatchSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var fileWatchDescriptor: Int32 = -1
    nonisolated(unsafe) private var parentDirWatchSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var parentDirWatchDescriptor: Int32 = -1
    nonisolated(unsafe) private var watchedFileInode: UInt64 = 0
    nonisolated(unsafe) private var externalHighlightClearTask: Task<Void, Never>?

    public init(
        remoteWorkspaceManager: RemoteWorkspaceManager? = nil,
        userDefaults: UserDefaults? = nil
    ) {
        let resolvedDefaults = userDefaults ?? remoteWorkspaceManager?.userDefaults ?? .standard
        let manager = remoteWorkspaceManager ?? RemoteWorkspaceManager(userDefaults: resolvedDefaults)
        self.userDefaults = resolvedDefaults
        self.remoteWorkspaceManager = manager

        if let data = resolvedDefaults.data(forKey: Self.typographyDefaultsKey),
           let decoded = try? JSONDecoder().decode(EditorTypographySettings.self, from: data) {
            self.typography = decoded
        } else {
            self.typography = .default
        }

        if let rawTheme = resolvedDefaults.string(forKey: Self.themeDefaultsKey),
           let decodedTheme = EditorTheme(rawValue: rawTheme) {
            self.theme = decodedTheme
        } else {
            self.theme = .daylight
        }

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

    private static func defaultFallbackWorkspaceFolderURL() -> URL {
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

    private static func resolvePersistedURL(
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

    private func persistWorkspaceFolder(_ folderURL: URL?) {
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

    private func persistCurrentFileBookmark() {
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

    private func persistDocumentSessionState() {
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

    deinit {
        externalHighlightClearTask?.cancel()
        stopWatchingCurrentFile()
    }

    public func resetTypographyToDefaults() {
        typography = .default
    }

    // MARK: - Infinite Undo & Redo Engine

    private func undoTimelineKey(for url: URL?) -> String {
        if let url {
            return url.standardizedFileURL.path
        }
        return "__UNTITLED_SCRATCHPAD__"
    }

    public var currentUndoStack: [DocumentUndoEntry] {
        perFileUndoTimelines[undoTimelineKey(for: currentFileURL)]?.undoStack ?? []
    }

    public var currentRedoStack: [DocumentUndoEntry] {
        perFileUndoTimelines[undoTimelineKey(for: currentFileURL)]?.redoStack ?? []
    }

    public var undoActionTitle: String {
        if let last = currentUndoStack.last {
            return "Undo \(last.summary)"
        }
        return "Undo"
    }

    public var redoActionTitle: String {
        if let last = currentRedoStack.last {
            return "Redo \(last.summary)"
        }
        return "Redo"
    }

    public func undoTimeline(for url: URL?) -> DocumentUndoTimeline {
        perFileUndoTimelines[undoTimelineKey(for: url)] ?? DocumentUndoTimeline()
    }

    private func refreshUndoRedoAvailability() {
        let timeline = perFileUndoTimelines[undoTimelineKey(for: currentFileURL)] ?? DocumentUndoTimeline()
        if canUndo != timeline.canUndo {
            canUndo = timeline.canUndo
        }
        if canRedo != timeline.canRedo {
            canRedo = timeline.canRedo
        }
    }

    private static let maxPersistedUndoEntriesPerFile = 100

    private func persistUndoTimelines() {
        guard !isRestoringState else { return }
        var boundedTimelines: [String: DocumentUndoTimeline] = [:]
        boundedTimelines.reserveCapacity(perFileUndoTimelines.count)
        for (key, timeline) in perFileUndoTimelines {
            let undoSlice = timeline.undoStack.suffix(Self.maxPersistedUndoEntriesPerFile)
            let redoSlice = timeline.redoStack.suffix(Self.maxPersistedUndoEntriesPerFile)
            boundedTimelines[key] = DocumentUndoTimeline(
                undoStack: Array(undoSlice),
                redoStack: Array(redoSlice)
            )
        }
        if let encoded = try? JSONEncoder().encode(boundedTimelines) {
            userDefaults.set(encoded, forKey: Self.undoTimelinesDefaultsKey)
        }
    }

    public func breakUndoCoalescing() {
        canCoalesceLiveTyping = false
    }

    public func withUndoMetadata<T>(
        origin: UndoEntryOrigin,
        summary: String? = nil,
        _ block: () -> T
    ) -> T {
        breakUndoCoalescing()
        let prevOrigin = pendingEditOrigin
        let prevSummary = pendingEditSummary
        pendingEditOrigin = origin
        pendingEditSummary = summary ?? origin.rawValue
        defer {
            pendingEditOrigin = prevOrigin
            pendingEditSummary = prevSummary
            breakUndoCoalescing()
        }
        return block()
    }

    private func recordUndoStep(
        from previousText: String,
        to newText: String,
        previousSelection: NSRange,
        newSelection: NSRange,
        origin: UndoEntryOrigin,
        summary: String? = nil,
        allowCoalescing: Bool = false
    ) {
        guard previousText != newText else { return }
        let key = undoTimelineKey(for: currentFileURL)
        var timeline = perFileUndoTimelines[key] ?? DocumentUndoTimeline()
        let now = Date()

        let prevNS = previousText as NSString
        let newNS = newText as NSString
        let deltaLen = newNS.length - prevNS.length
        let isSingleCharAlphanumeric: Bool = {
            guard deltaLen == 1,
                  previousSelection.length == 0,
                  newSelection.length == 0 else { return false }
            // Determine the UTF-16 index of the newly inserted character (either via cursor advance or diff prefix)
            var insertLoc = newSelection.location - 1
            if insertLoc < 0 || insertLoc >= newNS.length || newSelection.location != previousSelection.location + 1 {
                var prefix = 0
                let limit = prevNS.length
                while prefix < limit && prevNS.character(at: prefix) == newNS.character(at: prefix) {
                    prefix += 1
                }
                insertLoc = prefix
            }
            guard insertLoc >= 0 && insertLoc < newNS.length else { return false }
            let insertedStr = newNS.substring(with: NSRange(location: insertLoc, length: 1))
            guard let scalar = insertedStr.unicodeScalars.first, insertedStr.unicodeScalars.count == 1 else {
                return false
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar) {
                return false
            }
            return true
        }()

        if allowCoalescing,
           origin == .userTyping,
           isSingleCharAlphanumeric,
           var lastEntry = timeline.undoStack.last,
           lastEntry.origin == .userTyping,
           lastEntry.newText == previousText,
           lastEntry.newSelectedLocation == previousSelection.location,
           lastEntry.newSelectedLength == 0,
           now.timeIntervalSince(lastEntry.timestamp) < 0.65 {
            lastEntry.newText = newText
            lastEntry.newSelectedLocation = max(0, newSelection.location)
            lastEntry.newSelectedLength = max(0, newSelection.length)
            lastEntry.timestamp = now
            timeline.undoStack[timeline.undoStack.count - 1] = lastEntry
            timeline.redoStack.removeAll()
        } else {
            let entry = DocumentUndoEntry(
                previousText: previousText,
                newText: newText,
                previousSelectedRange: previousSelection,
                newSelectedRange: newSelection,
                timestamp: now,
                origin: origin,
                summary: summary
            )
            timeline.undoStack.append(entry)
            timeline.redoStack.removeAll()
            canCoalesceLiveTyping = (origin == .userTyping && isSingleCharAlphanumeric)
        }

        perFileUndoTimelines[key] = timeline
        refreshUndoRedoAvailability()
        persistUndoTimelines()
    }

    private func updateTopUndoNewSelection(_ selection: NSRange) {
        let key = undoTimelineKey(for: currentFileURL)
        guard var timeline = perFileUndoTimelines[key],
              !timeline.undoStack.isEmpty else { return }
        var last = timeline.undoStack[timeline.undoStack.count - 1]
        if last.newText == markdownText {
            last.newSelectedLocation = max(0, selection.location)
            last.newSelectedLength = max(0, selection.length)
            timeline.undoStack[timeline.undoStack.count - 1] = last
            perFileUndoTimelines[key] = timeline
            persistUndoTimelines()
        }
    }

    public func undo() {
        let key = undoTimelineKey(for: currentFileURL)
        guard var timeline = perFileUndoTimelines[key],
              let entry = timeline.undoStack.popLast() else { return }
        timeline.redoStack.append(entry)
        perFileUndoTimelines[key] = timeline
        canCoalesceLiveTyping = false

        applyHistoricalTextState(
            entry.previousText,
            selectedRange: entry.previousSelectedRange
        )
        refreshUndoRedoAvailability()
        persistUndoTimelines()
    }

    public func redo() {
        let key = undoTimelineKey(for: currentFileURL)
        guard var timeline = perFileUndoTimelines[key],
              let entry = timeline.redoStack.popLast() else { return }
        timeline.undoStack.append(entry)
        perFileUndoTimelines[key] = timeline
        canCoalesceLiveTyping = false

        applyHistoricalTextState(
            entry.newText,
            selectedRange: entry.newSelectedRange
        )
        refreshUndoRedoAvailability()
        persistUndoTimelines()
    }

    private func applyHistoricalTextState(_ targetText: String, selectedRange: NSRange) {
        let clampedLoc = max(0, min((targetText as NSString).length, selectedRange.location))
        let clampedLen = max(0, min((targetText as NSString).length - clampedLoc, selectedRange.length))
        let clampedRange = NSRange(location: clampedLoc, length: clampedLen)

        isApplyingInternalStateChange = true
        markdownText = targetText
        currentSelectedRange = clampedRange
        userDefaults.set(clampedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        stats = DocumentStats.compute(for: targetText, selectedRange: clampedRange)

        if let tv = activeTextView {
            tv.applyProgrammaticDocumentText(targetText, selectedRange: clampedRange)
        } else {
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: targetText),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: clampedRange
            )
            headings = analysis.headings
        }

        if let url = currentFileURL, autoSaveEnabled, activeConflict == nil {
            performDiskWrite(targetText, to: url)
            isDirty = false
        } else if currentFileURL == nil {
            isDirty = !autoSaveEnabled
        } else {
            isDirty = (targetText != lastSavedDiskContent)
        }
        isApplyingInternalStateChange = false
        persistDocumentSessionState()
    }

    // MARK: - Directory Expansion State
    public func isDirectoryExpanded(_ url: URL) -> Bool {
        !collapsedDirectoryPaths.contains(url.standardizedFileURL.path)
    }

    public func setDirectoryExpanded(_ expanded: Bool, for url: URL) {
        let key = url.standardizedFileURL.path
        if expanded {
            collapsedDirectoryPaths.remove(key)
        } else {
            collapsedDirectoryPaths.insert(key)
        }
    }

    public func toggleDirectoryExpanded(_ url: URL) {
        let key = url.standardizedFileURL.path
        if collapsedDirectoryPaths.contains(key) {
            collapsedDirectoryPaths.remove(key)
        } else {
            collapsedDirectoryPaths.insert(key)
        }
    }

    // MARK: - Document Title
    public var documentTitle: String {
        if let url = currentFileURL {
            return url.lastPathComponent
        }
        if let firstH1 = headings.first(where: { $0.level == 1 }) {
            return "\(firstH1.title).md"
        }
        return "Untitled.md"
    }

    // MARK: - Live Editor Updates
    public func handleEditorTextEdited(_ newText: String, selectedRange: NSRange) {
        let previousSel = currentSelectedRange
        currentSelectedRange = selectedRange
        if markdownText != newText {
            let oldText = markdownText
            isApplyingInternalStateChange = true
            markdownText = newText
            isApplyingInternalStateChange = false

            let allowCoalesce = canCoalesceLiveTyping
            recordUndoStep(
                from: oldText,
                to: newText,
                previousSelection: previousSel,
                newSelection: selectedRange,
                origin: pendingEditOrigin,
                summary: pendingEditSummary,
                allowCoalescing: allowCoalesce
            )
            pendingEditOrigin = .userTyping
            pendingEditSummary = nil
            updateTopUndoNewSelection(selectedRange)

            if activeTextView == nil {
                let analysis = MarkdownLiveStyler.applyStyles(
                    to: NSTextStorage(string: newText),
                    theme: theme,
                    typography: typography,
                    sourceCodeMode: sourceCodeMode,
                    focusMode: focusMode,
                    selectedRange: selectedRange
                )
                headings = analysis.headings
            }
            autoSaveOrStageCurrentDocument()
        }
        if !isRestoringState {
            userDefaults.set(selectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        }
        stats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
    }

    public func updateSelectionStats(selectedRange: NSRange) {
        if selectedRange != currentSelectedRange && !isLiveKeystrokeInProgress {
            canCoalesceLiveTyping = false
        }
        currentSelectedRange = selectedRange
        if !isRestoringState {
            userDefaults.set(selectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        }
        stats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
    }

    // MARK: - Task Checkbox Toggling
    public func toggleTaskCheckbox(at boxCharacterLocation: Int) {
        let nsStr = markdownText as NSString
        let boxRange = NSRange(location: boxCharacterLocation, length: 3)
        guard boxCharacterLocation >= 0, NSMaxRange(boxRange) <= nsStr.length else { return }

        let currentBox = nsStr.substring(with: boxRange)
        let replacement: String
        if currentBox.lowercased() == "[x]" {
            replacement = "[ ]"
        } else if currentBox == "[ ]" {
            replacement = "[x]"
        } else {
            return
        }

        withUndoMetadata(origin: .formattingAction, summary: "Toggle Task Checkbox") {
            if let tv = activeTextView, tv.shouldChangeText(in: boxRange, replacementString: replacement) {
                tv.replaceCharacters(in: boxRange, with: replacement)
                tv.didChangeText()
            } else {
                markdownText = nsStr.replacingCharacters(in: boxRange, with: replacement)
            }
        }
    }

    // MARK: - Navigation
    public func scrollToHeading(_ heading: OutlineHeading) {
        pendingScrollToCharacterLocation = heading.characterLocation
        activeHeadingID = heading.id
    }

    public func jumpToSearchMatch(_ match: WorkspaceSearchMatch) {
        if currentFileURL != match.fileURL {
            openFile(at: match.fileURL)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pendingScrollToCharacterLocation = match.matchRangeInFile.location
        }
    }

    // MARK: - Formatting & Markdown Insertion Commands
    public func applyInlineFormatting(prefix: String, suffix: String, placeholder: String) {
        withUndoMetadata(origin: .formattingAction, summary: "Inline Formatting") {
            guard let tv = activeTextView else {
                markdownText += "\(prefix)\(placeholder)\(suffix)"
                return
            }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let selectedText = sel.length > 0 ? nsStr.substring(with: sel) : placeholder
            let replacement = "\(prefix)\(selectedText)\(suffix)"

            if tv.shouldChangeText(in: sel, replacementString: replacement) {
                tv.replaceCharacters(in: sel, with: replacement)
                tv.didChangeText()
                let innerRange = NSRange(location: sel.location + (prefix as NSString).length, length: (selectedText as NSString).length)
                tv.setSelectedRange(innerRange)
            }
        }
    }

    /// Width for explicit reflow commands: the source line width, or the default when auto-wrap is off.
    public var effectiveReflowWidth: Int {
        sourceLineWidth > 0 ? sourceLineWidth : MarkdownSourceReflow.defaultWidth
    }

    /// Hard-wraps the paragraph at the cursor to `effectiveReflowWidth` columns.
    public func reflowCurrentParagraph() {
        withUndoMetadata(origin: .formattingAction, summary: "Reflow Paragraph") {
            guard let tv = activeTextView else { return }
            let text = tv.string
            let nsStr = text as NSString
            let sel = tv.selectedRange()
            let line = MarkdownSourceReflow.lineNumber(at: sel.location, in: nsStr)
            guard let edit = MarkdownSourceReflow.reflowParagraph(in: text, line: line, width: effectiveReflowWidth),
                  nsStr.substring(with: edit.range) != edit.replacement else { return }
            let newLocation = edit.range.location + MarkdownSourceReflow.mapLocation(
                sel.location, in: nsStr, oldRange: edit.range, to: edit.replacement as NSString
            )
            tv.breakUndoCoalescing()
            if tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                tv.replaceCharacters(in: edit.range, with: edit.replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: newLocation, length: 0))
            }
        }
    }

    /// Hard-wraps every paragraph in the document to `effectiveReflowWidth` columns.
    public func reflowDocument() {
        withUndoMetadata(origin: .formattingAction, summary: "Reflow Document") {
            guard let tv = activeTextView else {
                let reflowed = MarkdownSourceReflow.reflowDocument(markdownText, width: effectiveReflowWidth)
                if reflowed != markdownText {
                    markdownText = reflowed
                }
                return
            }
            let text = tv.string
            let nsStr = text as NSString
            let reflowed = MarkdownSourceReflow.reflowDocument(text, width: effectiveReflowWidth)
            guard reflowed != text else { return }
            let fullRange = NSRange(location: 0, length: nsStr.length)
            let newLocation = MarkdownSourceReflow.mapLocation(
                tv.selectedRange().location, in: nsStr, oldRange: fullRange, to: reflowed as NSString
            )
            tv.breakUndoCoalescing()
            if tv.shouldChangeText(in: fullRange, replacementString: reflowed) {
                tv.replaceCharacters(in: fullRange, with: reflowed)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: newLocation, length: 0))
            }
        }
    }

    public func setHeadingLevel(_ level: Int) {
        withUndoMetadata(origin: .formattingAction, summary: level == 0 ? "Convert to Paragraph" : "Heading \(level)") {
            guard let tv = activeTextView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
            var contentRange = lineRange
            while contentRange.length > 0 {
                let ch = nsStr.character(at: contentRange.location + contentRange.length - 1)
                if ch == 10 || ch == 13 { contentRange.length -= 1 } else { break }
            }
            let lineText = nsStr.substring(with: contentRange)
            let stripped = lineText.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)

            let replacement: String
            if level == 0 {
                replacement = stripped
            } else {
                let hashes = String(repeating: "#", count: min(6, max(1, level)))
                replacement = "\(hashes) \(stripped.isEmpty ? "Heading \(level)" : stripped)"
            }

            if tv.shouldChangeText(in: contentRange, replacementString: replacement) {
                tv.replaceCharacters(in: contentRange, with: replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: contentRange.location + (replacement as NSString).length, length: 0))
            }
        }
    }

    public func insertBlockquote() {
        prefixCurrentLine(with: "> ", summary: "Insert Blockquote")
    }

    public func insertUnorderedList() {
        prefixCurrentLine(with: "- ", summary: "Insert Bullet List")
    }

    public func insertOrderedList() {
        prefixCurrentLine(with: "1. ", summary: "Insert Numbered List")
    }

    public func insertTaskList() {
        prefixCurrentLine(with: "- [ ] ", summary: "Insert Task List")
    }

    private func prefixCurrentLine(with prefix: String, summary: String = "Format Line") {
        withUndoMetadata(origin: .formattingAction, summary: summary) {
            guard let tv = activeTextView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if tv.shouldChangeText(in: insertRange, replacementString: prefix) {
                tv.replaceCharacters(in: insertRange, with: prefix)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: 0))
            }
        }
    }

    public func insertCodeFence(language: String = "swift") {
        let snippet = "\n```\(language)\n\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 5 + language.count, summary: "Insert Code Block")
    }

    public func insertMathBlock() {
        let snippet = "\n$$\n\\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}\n$$\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 4, summary: "Insert Math Block")
    }

    public func insertMermaidBlock() {
        let snippet = "\n```mermaid\ngraph TD\n    A[Start] --> B[End]\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 12)
    }

    public func insertSVGBlock() {
        let snippet = "\n```svg\n<svg viewBox=\"0 0 120 40\"><rect x=\"4\" y=\"4\" width=\"112\" height=\"32\" rx=\"6\" fill=\"#3b82f6\"/><text x=\"60\" y=\"25\" fill=\"#ffffff\" text-anchor=\"middle\" font-size=\"13\">SVG</text></svg>\n```\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 8)
    }

    public func insertHorizontalRule() {
        let snippet = "\n---\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: snippet.count, summary: "Insert Horizontal Rule")
    }

    public func insertTable(rows: Int, columns: Int) {
        let r = max(1, min(30, rows))
        let c = max(1, min(12, columns))
        let headers = (1...c).map { "Header \($0)" }.joined(separator: " | ")
        let sep = (1...c).map { _ in "---" }.joined(separator: " | ")
        var tableLines = [
            "| \(headers) |",
            "| \(sep) |"
        ]
        for rowIdx in 1...r {
            let cells = (1...c).map { "Row \(rowIdx) Col \($0)" }.joined(separator: " | ")
            tableLines.append("| \(cells) |")
        }
        let snippet = "\n" + tableLines.joined(separator: "\n") + "\n"
        insertSnippetAtCursor(snippet, cursorOffsetFromStart: 3, summary: "Insert Table")
    }

    private func insertSnippetAtCursor(_ snippet: String, cursorOffsetFromStart: Int, summary: String = "Insert Snippet") {
        withUndoMetadata(origin: .formattingAction, summary: summary) {
            guard let tv = activeTextView else {
                markdownText += snippet
                return
            }
            let sel = tv.selectedRange()
            if tv.shouldChangeText(in: sel, replacementString: snippet) {
                tv.replaceCharacters(in: sel, with: snippet)
                tv.didChangeText()
                let newCursor = min((tv.string as NSString).length, sel.location + cursorOffsetFromStart)
                tv.setSelectedRange(NSRange(location: newCursor, length: 0))
            }
        }
    }

    // MARK: - Find & Replace in Current Document
    public func findNextInDocument() {
        guard !findQuery.isEmpty, let tv = activeTextView else { return }
        let nsStr = tv.string as NSString
        let startLoc = min(NSMaxRange(tv.selectedRange()), nsStr.length)
        let searchRange = NSRange(location: startLoc, length: nsStr.length - startLoc)

        var found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: searchRange)
        if found.location == NSNotFound && startLoc > 0 {
            found = nsStr.range(of: findQuery, options: [.caseInsensitive], range: NSRange(location: 0, length: startLoc))
        }
        if found.location != NSNotFound {
            tv.setSelectedRange(found)
            tv.scrollRangeToVisible(found)
        }
    }

    public func replaceCurrentMatch() {
        guard !findQuery.isEmpty, let tv = activeTextView else { return }
        let sel = tv.selectedRange()
        let nsStr = tv.string as NSString
        if sel.length > 0 && nsStr.substring(with: sel).caseInsensitiveCompare(findQuery) == .orderedSame {
            withUndoMetadata(origin: .findReplace, summary: "Replace") {
                if tv.shouldChangeText(in: sel, replacementString: replaceQuery) {
                    tv.replaceCharacters(in: sel, with: replaceQuery)
                    tv.didChangeText()
                }
            }
        }
        findNextInDocument()
    }

    public func replaceAllInDocument() {
        guard !findQuery.isEmpty else { return }
        let updated = markdownText.replacingOccurrences(of: findQuery, with: replaceQuery, options: [.caseInsensitive])
        if updated != markdownText {
            withUndoMetadata(origin: .findReplace, summary: "Replace All") {
                markdownText = updated
                if let tv = activeTextView {
                    let clamped = DocumentLineDiff.adjustedSelection(
                        for: tv.selectedRange(),
                        inOldText: tv.string,
                        toNewText: updated
                    )
                    tv.applyProgrammaticDocumentText(updated, selectedRange: clamped)
                }
            }
        }
    }

    // MARK: - Autosave, External Updates & Conflict Resolution

    private func autoSaveOrStageCurrentDocument() {
        if let url = currentFileURL {
            if autoSaveEnabled && activeConflict == nil {
                // Before overwriting disk, verify whether an external process modified the file since our last save
                if let currentDiskText = try? String(contentsOf: url, encoding: .utf8),
                   currentDiskText != lastSavedDiskContent,
                   !recentSelfWrittenContents.contains(currentDiskText) {
                    let mergeResult = ThreeWayDocumentMerger.merge(
                        base: lastSavedDiskContent,
                        local: markdownText,
                        external: currentDiskText,
                        fileURL: url,
                        sourceDescription: remoteWorkspaceManager.isRemoteURL(url) ? "SSH Remote" : "Disk"
                    )
                    switch mergeResult {
                    case .clean(let mergedText, let wasAutoMerged):
                        if mergedText != markdownText {
                            let localBeforeMerge = markdownText
                            let diff = DocumentLineDiff.computeDiff(from: localBeforeMerge, to: mergedText)
                            let adjustedSel = DocumentLineDiff.adjustedSelection(
                                for: currentSelectedRange,
                                inOldText: localBeforeMerge,
                                toNewText: mergedText
                            )
                            recordUndoStep(
                                from: localBeforeMerge,
                                to: mergedText,
                                previousSelection: currentSelectedRange,
                                newSelection: adjustedSel,
                                origin: .externalUpdate,
                                summary: wasAutoMerged ? "Auto-merged external changes" : "External file update",
                                allowCoalescing: false
                            )
                            isApplyingInternalStateChange = true
                            markdownText = mergedText
                            currentSelectedRange = adjustedSel
                            if let tv = activeTextView {
                                tv.applyProgrammaticDocumentText(mergedText, selectedRange: adjustedSel)
                            }
                            isApplyingInternalStateChange = false
                            publishExternalUpdateVisualNotice(
                                fileURL: url,
                                previousText: localBeforeMerge,
                                updatedText: mergedText,
                                diff: diff,
                                wasAutoMerged: wasAutoMerged,
                                sourceDescription: remoteWorkspaceManager.isRemoteURL(url) ? "SSH Remote" : "Disk"
                            )
                        }
                        performDiskWrite(mergedText, to: url)
                        isDirty = false
                    case .conflict(let conflict):
                        activeConflict = conflict
                        isDirty = true
                    }
                    persistDocumentSessionState()
                    return
                }

                performDiskWrite(markdownText, to: url)
                isDirty = false
            } else {
                isDirty = (markdownText != lastSavedDiskContent)
            }
        } else {
            isDirty = !autoSaveEnabled
        }
        persistDocumentSessionState()
    }

    private func performDiskWrite(_ content: String, to url: URL) {
        do {
            recentSelfWrittenContents.append(content)
            if recentSelfWrittenContents.count > 128 {
                recentSelfWrittenContents.removeFirst(recentSelfWrittenContents.count - 128)
            }
            lastSavedDiskContent = content
            let utf8Data = Data(content.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                try utf8Data.write(to: url)
            } else {
                try utf8Data.write(to: url, options: .atomic)
            }
            lastAutoSavedAt = Date()
            isDirty = false

            if currentFileURL?.standardizedFileURL == url.standardizedFileURL {
                let newInode = Self.fileInode(for: url)
                if watchedFileInode == 0 || newInode != watchedFileInode {
                    watchFileDescriptorOnly(url)
                }
            }

            if remoteWorkspaceManager.isRemoteURL(url) {
                Task { @MainActor in
                    await remoteWorkspaceManager.saveRemoteFile(at: url, content: content)
                }
            }
        } catch {
            NSSound.beep()
        }
    }

    private func flushPendingAutoSaveBeforeSwitchingFile() {
        guard let url = currentFileURL,
              activeConflict == nil,
              autoSaveEnabled,
              markdownText != lastSavedDiskContent else { return }
        performDiskWrite(markdownText, to: url)
    }

    /// Checks whether the currently open file on disk has been modified by an external process,
    /// and either auto-updates, 3-way auto-merges, or triggers conflict resolution.
    public func checkForExternalFileChanges(for targetURL: URL? = nil, sourceDescription: String? = nil) {
        guard let currentURL = targetURL ?? currentFileURL else { return }
        guard currentFileURL?.standardizedFileURL == currentURL.standardizedFileURL else { return }
        guard let diskContent = try? String(contentsOf: currentURL, encoding: .utf8) else { return }

        let currentInode = Self.fileInode(for: currentURL)
        if currentInode != 0 && currentInode != watchedFileInode {
            watchFileDescriptorOnly(currentURL)
        }

        // Ignore self-writes when no conflict is active and disk matches our buffer
        if activeConflict == nil,
           diskContent == markdownText,
           (diskContent == lastSavedDiskContent || recentSelfWrittenContents.contains(diskContent)) {
            lastSavedDiskContent = diskContent
            return
        }

        // Also ignore asynchronous watcher echo from an older self-write that we already superseded
        if activeConflict == nil,
           diskContent != markdownText,
           recentSelfWrittenContents.contains(diskContent),
           markdownText == lastSavedDiskContent {
            return
        }

        let effectiveSource = sourceDescription ?? (remoteWorkspaceManager.isRemoteURL(currentURL) ? "SSH Remote" : "Disk")
        handleExternalFileUpdate(diskContent: diskContent, for: currentURL, sourceDescription: effectiveSource)
    }

    public func handleExternalFileUpdate(
        diskContent: String,
        for url: URL,
        sourceDescription: String = "Disk"
    ) {
        guard currentFileURL?.standardizedFileURL == url.standardizedFileURL else { return }

        let baseText = lastSavedDiskContent
        let localText = markdownText

        let mergeResult = ThreeWayDocumentMerger.merge(
            base: baseText,
            local: localText,
            external: diskContent,
            fileURL: url,
            sourceDescription: sourceDescription
        )

        switch mergeResult {
        case .clean(let mergedText, let wasAutoMerged):
            activeConflict = nil
            showConflictResolverModal = false

            if mergedText != localText {
                let diff = DocumentLineDiff.computeDiff(from: localText, to: mergedText)
                let adjustedSel = DocumentLineDiff.adjustedSelection(
                    for: currentSelectedRange,
                    inOldText: localText,
                    toNewText: mergedText
                )

                recordUndoStep(
                    from: localText,
                    to: mergedText,
                    previousSelection: currentSelectedRange,
                    newSelection: adjustedSel,
                    origin: .externalUpdate,
                    summary: wasAutoMerged ? "Auto-merged external changes" : "External file update",
                    allowCoalescing: false
                )

                isApplyingInternalStateChange = true
                markdownText = mergedText
                currentSelectedRange = adjustedSel
                stats = DocumentStats.compute(for: mergedText, selectedRange: adjustedSel)
                if let tv = activeTextView {
                    tv.applyProgrammaticDocumentText(mergedText, selectedRange: adjustedSel)
                } else {
                    let analysis = MarkdownLiveStyler.applyStyles(
                        to: NSTextStorage(string: mergedText),
                        theme: theme,
                        typography: typography,
                        sourceCodeMode: sourceCodeMode,
                        focusMode: focusMode,
                        selectedRange: adjustedSel
                    )
                    headings = analysis.headings
                }
                isApplyingInternalStateChange = false

                publishExternalUpdateVisualNotice(
                    fileURL: url,
                    previousText: localText,
                    updatedText: mergedText,
                    diff: diff,
                    wasAutoMerged: wasAutoMerged,
                    sourceDescription: sourceDescription
                )
            }

            lastSavedDiskContent = mergedText
            isDirty = false
            if wasAutoMerged && mergedText != diskContent {
                performDiskWrite(mergedText, to: url)
            }
            persistDocumentSessionState()

        case .conflict(let conflict):
            activeConflict = conflict
            isDirty = true
            persistDocumentSessionState()
        }
    }

    private func publishExternalUpdateVisualNotice(
        fileURL: URL,
        previousText: String,
        updatedText: String,
        diff: DocumentLineDiffResult,
        wasAutoMerged: Bool,
        sourceDescription: String
    ) {
        externalUpdateNotice = ExternalUpdateNotice(
            fileURL: fileURL,
            previousText: previousText,
            updatedText: updatedText,
            addedLinesCount: diff.addedLinesCount,
            removedLinesCount: diff.removedLinesCount,
            changedLineNumbers: diff.changedLineNumbers,
            changedCharacterRanges: diff.changedCharacterRanges,
            diffHunks: diff.hunks,
            wasAutoMerged: wasAutoMerged,
            sourceDescription: sourceDescription
        )
        externalUpdateHighlightRanges = diff.changedCharacterRanges

        externalHighlightClearTask?.cancel()
        externalHighlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.externalUpdateHighlightRanges = []
        }
    }

    public func dismissExternalUpdateNotice() {
        externalHighlightClearTask?.cancel()
        externalUpdateNotice = nil
        externalUpdateHighlightRanges = []
        showExternalUpdateDiffModal = false
    }

    public func resolveConflict(using strategy: ConflictResolutionStrategy) {
        guard let conflict = activeConflict else { return }
        let resolved = conflict.resolvedText(using: strategy)
        applyResolvedConflictText(
            resolved,
            for: conflict,
            summary: "Resolved conflict (\(strategy.rawValue))"
        )
    }

    public func setConflictHunkResolution(_ strategy: ConflictResolutionStrategy, forHunkID hunkID: UUID) {
        activeConflict?.setResolution(strategy, forHunkID: hunkID)
    }

    public func applyInteractiveConflictResolution() {
        guard let conflict = activeConflict else { return }
        let resolved = conflict.resolvedText(using: nil)
        applyResolvedConflictText(
            resolved,
            for: conflict,
            summary: "Resolved conflict (Custom Merge)"
        )
    }

    private func applyResolvedConflictText(
        _ resolved: String,
        for conflict: DocumentConflict,
        summary: String
    ) {
        let previousLocal = markdownText
        let baselineForUndo = (previousLocal != resolved) ? previousLocal : conflict.externalText
        let adjustedSel = DocumentLineDiff.adjustedSelection(
            for: currentSelectedRange,
            inOldText: previousLocal,
            toNewText: resolved
        )

        recordUndoStep(
            from: baselineForUndo,
            to: resolved,
            previousSelection: currentSelectedRange,
            newSelection: adjustedSel,
            origin: .conflictResolution,
            summary: summary,
            allowCoalescing: false
        )

        activeConflict = nil
        showConflictResolverModal = false

        isApplyingInternalStateChange = true
        markdownText = resolved
        currentSelectedRange = adjustedSel
        isDirty = false
        stats = DocumentStats.compute(for: resolved, selectedRange: adjustedSel)
        if let tv = activeTextView {
            tv.applyProgrammaticDocumentText(resolved, selectedRange: adjustedSel)
        } else {
            let analysis = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: resolved),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: adjustedSel
            )
            headings = analysis.headings
        }
        isApplyingInternalStateChange = false

        performDiskWrite(resolved, to: conflict.fileURL)
        let diff = DocumentLineDiff.computeDiff(from: baselineForUndo, to: resolved)
        externalUpdateHighlightRanges = diff.changedCharacterRanges
        persistDocumentSessionState()
    }

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
            recentSelfWrittenContents.removeAll()
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

    private func writeDocument(to url: URL) {
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

    private func addRecentFile(_ url: URL) {
        recentFileURLs.removeAll(where: { $0.standardizedFileURL == url.standardizedFileURL })
        recentFileURLs.insert(url, at: 0)
        if recentFileURLs.count > 15 {
            recentFileURLs = Array(recentFileURLs.prefix(15))
        }
    }

    // MARK: - POSIX DispatchSource File & Parent Directory Watcher

    private nonisolated static func fileInode(for url: URL) -> UInt64 {
        var st = stat()
        if stat(url.path, &st) == 0 {
            return UInt64(st.st_ino)
        }
        return 0
    }

    private func watchCurrentFile(_ url: URL) {
        stopWatchingCurrentFile()
        watchFileDescriptorOnly(url)
        watchParentDirectoryOnly(url.deletingLastPathComponent())
    }

    private func watchFileDescriptorOnly(_ url: URL) {
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

    private func watchParentDirectoryOnly(_ parentURL: URL) {
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

    nonisolated private func stopWatchingCurrentFile() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        fileWatchDescriptor = -1
        parentDirWatchSource?.cancel()
        parentDirWatchSource = nil
        parentDirWatchDescriptor = -1
        watchedFileInode = 0
    }

    // MARK: - Workspace Folder Tree & Multi-file Search
    public func loadWorkspaceFolder(_ folderURL: URL) {
        workspaceFolderURL = folderURL
        reloadWorkspaceTree()
    }

    public func reloadWorkspaceTree() {
        var flatList: [WorkspaceFileNode] = []
        var combinedRoots: [WorkspaceFileNode] = []

        if let folderURL = workspaceFolderURL {
            combinedRoots.append(contentsOf: scanDirectory(at: folderURL, depth: 0, remoteMountID: nil, flatAccumulator: &flatList))
        }

        // Append mounted remote folders & files into the unified multi-root tree
        for mount in remoteWorkspaceManager.mounts {
            let mirrorDir = remoteWorkspaceManager.localMirrorDirectory(for: mount)
            switch mount.targetKind {
            case .folder:
                let remoteChildren = scanDirectory(at: mirrorDir, depth: 0, remoteMountID: mount.id, flatAccumulator: &flatList)
                let rootNode = WorkspaceFileNode(
                    url: mirrorDir,
                    name: mount.effectiveDisplayName,
                    isDirectory: true,
                    modificationDate: Date(),
                    creationDate: Date(),
                    children: remoteChildren,
                    remoteMountID: mount.id,
                    isRemoteRoot: true,
                    remoteConnectionString: mount.connectionSpecString,
                    syncStatus: nil
                )
                combinedRoots.append(rootNode)

            case .file:
                let filename = (mount.remotePath as NSString).lastPathComponent
                let fileURL = remoteWorkspaceManager.localFileURL(for: filename, in: mount)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try? FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
                    try? "".write(to: fileURL, atomically: true, encoding: .utf8)
                }
                let rv = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let fileNode = WorkspaceFileNode(
                    url: fileURL,
                    name: mount.displayName ?? filename,
                    isDirectory: false,
                    modificationDate: rv?.contentModificationDate ?? Date(),
                    creationDate: rv?.creationDate ?? Date(),
                    children: nil,
                    remoteMountID: mount.id,
                    isRemoteRoot: true,
                    remoteConnectionString: mount.connectionSpecString,
                    syncStatus: remoteWorkspaceManager.fileSyncStatuses[fileURL.standardizedFileURL] ?? .synced
                )
                combinedRoots.append(fileNode)
                if fileNode.isMarkdownFile {
                    flatList.append(fileNode)
                }
            }
        }

        rootFileNodes = combinedRoots
        sortFileNodes()
        flatMarkdownFiles = sortNodesArray(flatList, by: fileSortOrder)
    }

    private func scanDirectory(
        at url: URL,
        depth: Int,
        remoteMountID: UUID?,
        flatAccumulator: inout [WorkspaceFileNode]
    ) -> [WorkspaceFileNode] {
        guard depth < 4 else { return [] }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let ignoredDirs: Set<String> = [
            ".build", ".git", "node_modules", "DerivedData", ".swiftpm",
            "target", "bazel-bin", "bazel-out", "bazel-testlogs", "bazel-Folio",
            "Folio.app", "vendor", "dist", "build"
        ]
        var nodes: [WorkspaceFileNode] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent
            if ignoredDirs.contains(name) || name.hasPrefix("bazel-") || name.hasSuffix(".app") { continue }

            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate ?? Date.distantPast
            let createDate = resourceValues?.creationDate ?? Date.distantPast

            if isDir {
                let children = scanDirectory(at: itemURL, depth: depth + 1, remoteMountID: remoteMountID, flatAccumulator: &flatAccumulator)
                if !children.isEmpty {
                    let node = WorkspaceFileNode(
                        url: itemURL,
                        name: name,
                        isDirectory: true,
                        modificationDate: modDate,
                        creationDate: createDate,
                        children: children,
                        remoteMountID: remoteMountID
                    )
                    nodes.append(node)
                }
            } else {
                let stdURL = itemURL.standardizedFileURL
                let syncStat = remoteMountID != nil ? (remoteWorkspaceManager.fileSyncStatuses[stdURL] ?? .synced) : nil
                let node = WorkspaceFileNode(
                    url: itemURL,
                    name: name,
                    isDirectory: false,
                    modificationDate: modDate,
                    creationDate: createDate,
                    children: nil,
                    remoteMountID: remoteMountID,
                    syncStatus: syncStat
                )
                if node.isMarkdownFile {
                    nodes.append(node)
                    flatAccumulator.append(node)
                }
            }
        }

        return sortNodesArray(nodes, by: fileSortOrder)
    }

    public func sortFileNodes() {
        rootFileNodes = sortNodesArray(rootFileNodes, by: fileSortOrder)
        flatMarkdownFiles = sortNodesArray(flatMarkdownFiles, by: fileSortOrder)
    }

    private func sortNodesArray(_ nodes: [WorkspaceFileNode], by order: FileSortOrder) -> [WorkspaceFileNode] {
        nodes.map { node in
            var copy = node
            if let children = copy.children {
                copy.children = sortNodesArray(children, by: order)
            }
            return copy
        }.sorted { a, b in
            // Keep remote root mounts grouped cleanly at the top of the tree or alongside folders
            if a.isRemoteRoot != b.isRemoteRoot {
                return a.isRemoteRoot
            }
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch order {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .modificationDate:
                return a.modificationDate > b.modificationDate
            case .creationDate:
                return a.creationDate > b.creationDate
            }
        }
    }

    public func performWorkspaceSearch() {
        let query = workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            workspaceSearchMatches = []
            return
        }

        var results: [WorkspaceSearchMatch] = []
        let pattern: String
        if searchUseRegex {
            pattern = query
        } else if searchWholeWord {
            pattern = "\\b\(NSRegularExpression.escapedPattern(for: query))\\b"
        } else {
            pattern = NSRegularExpression.escapedPattern(for: query)
        }

        let regexOptions: NSRegularExpression.Options = searchCaseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            workspaceSearchMatches = []
            return
        }

        // Also search current active buffer first if unsaved
        if currentFileURL == nil {
            searchInText(
                markdownText,
                fileURL: URL(fileURLWithPath: "/Untitled.md"),
                fileName: documentTitle,
                regex: regex,
                results: &results
            )
        }

        for fileNode in flatMarkdownFiles {
            guard let text = try? String(contentsOf: fileNode.url, encoding: .utf8) else { continue }
            searchInText(text, fileURL: fileNode.url, fileName: fileNode.name, regex: regex, results: &results)
            if results.count >= 200 { break }
        }

        workspaceSearchMatches = results
    }

    private func searchInText(
        _ text: String,
        fileURL: URL,
        fileName: String,
        regex: NSRegularExpression,
        results: inout [WorkspaceSearchMatch]
    ) {
        let nsStr = text as NSString
        var index = 0
        var lineNum = 1
        while index < nsStr.length {
            let lineRange = nsStr.lineRange(for: NSRange(location: index, length: 0))
            if let match = regex.firstMatch(in: text, options: [], range: lineRange) {
                let snippet = nsStr.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchMatch(
                    fileURL: fileURL,
                    fileName: fileName,
                    lineNumber: lineNum,
                    lineSnippet: snippet,
                    matchRangeInFile: match.range
                ))
            }
            index = NSMaxRange(lineRange)
            lineNum += 1
        }
    }

    // MARK: - HTML & PDF Export
    public func exportToHTML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = documentTitle.replacingOccurrences(of: ".md", with: "") + ".html"
        panel.directoryURL = workspaceFolderURL ?? currentFileURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url {
            let html = generateStandaloneHTML()
            try? html.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    public func exportToPDF() {
        guard let tv = activeTextView else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        let op = NSPrintOperation(view: tv, printInfo: printInfo)
        op.RunModal()
    }

    public func generateStandaloneHTML() -> String {
        let escapedLines = markdownText.components(separatedBy: .newlines).map { line -> String in
            if line.hasPrefix("# ") { return "<h1>\(line.dropFirst(2))</h1>" }
            if line.hasPrefix("## ") { return "<h2>\(line.dropFirst(3))</h2>" }
            if line.hasPrefix("### ") { return "<h3>\(line.dropFirst(4))</h3>" }
            if line.hasPrefix("> ") { return "<blockquote>\(line.dropFirst(2))</blockquote>" }
            if line.trimmingCharacters(in: .whitespaces) == "---" { return "<hr/>" }
            if line.isEmpty { return "" }
            return "<p>\(line)</p>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(documentTitle)</title>
        <style>
        body {
            max-width: \(Int(theme.maxWriteWidth))px;
            margin: 40px auto;
            padding: 0 24px;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Georgia, serif;
            font-size: \(Int(theme.baseFontSize))px;
            line-height: 1.6;
        }
        blockquote { border-left: 4px solid #dfe2e5; padding-left: 16px; color: #6a737d; }
        pre, code { background: #f6f8fa; border-radius: 4px; padding: 2px 6px; font-family: ui-monospace, Menlo, monospace; }
        </style>
        </head>
        <body>
        \(escapedLines)
        </body>
        </html>
        """
    }

    // MARK: - Default Showcase Document
    public static let defaultWelcomeDocument = """
    # Folio — Native macOS Markdown Editor
    Welcome to **Folio**, a lightning-fast **100% native macOS** (`AppKit` + `TextKit` + `SwiftUI`) Markdown editor built for distraction-free writing.
    > **Seamless Live Rendering**: Place your cursor on any line to reveal and edit its raw Markdown tokens (`#`, `**`, `` ` ``, `[link](url)`). Move the cursor away and the syntax markers collapse cleanly into live typography—with zero WebView overhead.
    ---
    ## Key Features
    - [x] **Seamless Hybrid WYSIWYG Editor** (`HybridMarkdownTextView`) with zero-latency native TextKit layout
    - [x] **6 Curated Themes**: *Daylight*, *Midnight*, *Parchment*, *Editorial*, *Classic*, and *Modernist*
    - [x] **Focus Mode** (`F8`) & **Typewriter Mode** (`F9`) & **Source Code Mode** (`Cmd+/`)
    - [x] **Hierarchical Sidebar** (`Cmd+Shift+L`): Document **Outline**, **Files** (Tree & List views), and **Global Search**
    - [x] **Quick Open Modal** (`Cmd+P`) for instant fuzzy file switching
    - [x] **Live Word Count Popover** showing Words, Lines, Characters, and Reading Time
    ### Inline Typography & Math
    You can write **bold text**, *italicized emphasis*, ~~strikethrough~~, ==highlighted notes==, `inline code`, and [clickable links](https://example.com) effortlessly. Inline math like $E = mc^2$ and $\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}$ is styled live.
    $$
    \\mathcal{L}_{\\text{Folio}} = \\int_{-\\infty}^{\\infty} \\psi^*(x) \\left( -\\frac{\\hbar^2}{2m}\\nabla^2 + V(x) \\right) \\psi(x)\\,dx
    $$
    ### Native Code Fences with Syntax Highlighting
    ```swift
    import AppKit
    // Pure native TextKit rendering — 0 MB WebView footprint
    final class FolioEngine {
        func renderLiveMarkdown(in storage: NSTextStorage) -> Bool {
            let latencyMs = 0.15
            return latencyMs < 1.0
        }
    }
    ```
    ### Live Markdown Tables
    | Subsystem | Architecture | Performance |
    | :--- | :--- | :--- |
    | **UI Layer** | Pure `AppKit` + `SwiftUI` | Native 120Hz ProMotion |
    | **Editor Engine** | Native `NSTextStorage` + `TextKit` | Sub-millisecond restyling |
    | **State Sync** | Direct in-memory Swift state | Zero IPC serialization |
    | **Themes** | 6 Native `EditorTheme` Palettes | Instant switching |
    ### Rich Media, Diagrams & Inline HTML (Pretty Mode)
    Press <kbd>Cmd+Shift+P</kbd> for the Command Palette or toggle **Pretty Mode** with <kbd>Cmd+Shift+Backslash</kbd> to render <mark>inline HTML highlights</mark>, <u>underlines</u>, H<sub>2</sub>O, and x<sup>2</sup>.
    ```mermaid
    flowchart LR
        Markdown["Markdown Source"] --> Engine["Folio Rust Engine"]
        Engine --> Native["120Hz Native Canvas"]
    ```
    """
}

@MainActor
private extension NSPrintOperation {
    func RunModal() {
        run()
    }
}
