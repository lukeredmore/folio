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
    @Published public var lastAutoSavedAt: Date?
    @Published public var lastSavedDiskContent: String = ""
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    @Published public var externalUpdateNotice: ExternalUpdateNotice?
    @Published public var externalUpdateHighlightRanges: [NSRange] = []
    @Published public var showExternalUpdateDiffModal: Bool = false
    @Published public var activeConflict: DocumentConflict?
    @Published public var showConflictResolverModal: Bool = false

    var perFileUndoTimelines: [String: DocumentUndoTimeline] = [:]
    public var currentSelectedRange: NSRange = NSRange(location: 0, length: 0)
    var isApplyingInternalStateChange: Bool = false
    var pendingEditOrigin: UndoEntryOrigin = .userTyping
    var pendingEditSummary: String?
    var canCoalesceLiveTyping: Bool = false
    public var isLiveKeystrokeInProgress: Bool = false
    var recentSelfWrittenContents: [String] = []

    // MARK: - Editor Modes, Theme & Typography
    var isSyncingThemeTypography: Bool = false

    @Published public var customThemes: [EditorTheme] = [] {
        didSet {
            guard !isRestoringState else { return }
            if let encoded = try? JSONEncoder().encode(customThemes) {
                userDefaults.set(encoded, forKey: Self.customThemesDefaultsKey)
            }
        }
    }

    @Published public var theme: EditorTheme = .daylight {
        didSet {
            if !isSyncingThemeTypography && typography != theme.typography {
                isSyncingThemeTypography = true
                typography = theme.typography
                isSyncingThemeTypography = false
            }
            guard !isRestoringState else { return }
            persistActiveThemeState()
        }
    }
    @Published public var typography: EditorTypographySettings = .default {
        didSet {
            if !isSyncingThemeTypography && theme.typography != typography {
                isSyncingThemeTypography = true
                theme.typography = typography
                isSyncingThemeTypography = false
            }
            guard !isRestoringState else { return }
            persistActiveThemeState()
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
    var cancellables: Set<AnyCancellable> = []
    var isRestoringState: Bool = true

    @Published public var workspaceSearchQuery: String = ""
    @Published public var searchCaseSensitive: Bool = false
    @Published public var searchWholeWord: Bool = false
    @Published public var searchUseRegex: Bool = false
    @Published public var workspaceSearchMatches: [WorkspaceSearchMatch] = []

    public weak var activeTextView: HybridMarkdownTextView?

    public static let typographyDefaultsKey = "Folio.EditorTypographySettings.v2"
    public static let customThemesDefaultsKey = "Folio.CustomEditorThemes.v1"
    public static let activeThemeDataDefaultsKey = "Folio.ActiveEditorThemeData.v1"
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

    nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) var fileWatchDescriptor: Int32 = -1
    nonisolated(unsafe) var parentDirWatchSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) var parentDirWatchDescriptor: Int32 = -1
    nonisolated(unsafe) var watchedFileInode: UInt64 = 0
    nonisolated(unsafe) var externalHighlightClearTask: Task<Void, Never>?

    public init(
        remoteWorkspaceManager: RemoteWorkspaceManager? = nil,
        userDefaults: UserDefaults? = nil
    ) {
        let resolvedDefaults = userDefaults ?? remoteWorkspaceManager?.userDefaults ?? .standard
        let manager = remoteWorkspaceManager ?? RemoteWorkspaceManager(userDefaults: resolvedDefaults)
        self.userDefaults = resolvedDefaults
        self.remoteWorkspaceManager = manager
        self.markdownText = Self.defaultWelcomeDocument
        restoreStateOnInit(resolvedDefaults: resolvedDefaults, manager: manager)
    }

    deinit {
        externalHighlightClearTask?.cancel()
        stopWatchingCurrentFile()
    }

    public func resetTypographyToDefaults() {
        typography = .default
    }
}
