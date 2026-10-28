import AppKit
import Combine
import Foundation
import SwiftUI

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
                reconcileSelectionComments(from: oldValue, to: markdownText)
                stats = DocumentStats.compute(for: markdownText, selectedRange: currentSelectedRange)
                if activeTextView == nil {
                    let analysis = MarkdownLiveStyler.applyStyles(
                        to: NSTextStorage(string: markdownText),
                        theme: theme,
                        typography: typography,
                        sourceCodeMode: sourceCodeMode,
                        focusMode: focusMode,
                        selectedRange: currentSelectedRange,
                        baseDirectoryURL: currentFileURL?.deletingLastPathComponent() ?? workspaceFolderURL,
                        fileURL: currentFileURL
                    )
                    headings = analysis.headings
                }
                scheduleAutoSave()
            } else if !isApplyingInternalStateChange {
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
            guard !isRestoringState, isDirty != oldValue else { return }
            if !isLiveKeystrokeInProgress || autoSaveDelay <= 0 {
                persistDocumentSessionState()
            }
        }
    }

    // MARK: - Autosave, Infinite Undo & External Update / Conflict State
    @Published public var autoSaveEnabled: Bool = true
    @Published public var lastAutoSavedAt: Date?
    @Published public var lastSavedDiskContent: String = ""
    /// File created by New File; deleted if the user leaves it without editing.
    var untouchedNewFile: (url: URL, template: String)?
    @Published public var canUndo: Bool = false
    @Published public var canRedo: Bool = false
    @Published public var externalUpdateNotice: ExternalUpdateNotice?
    @Published public var externalUpdateHighlightRanges: [NSRange] = []
    @Published public var showExternalUpdateDiffModal: Bool = false
    @Published public var activeConflict: DocumentConflict?
    @Published public var showConflictResolverModal: Bool = false

    /// Undo history for every file, shared with the other document windows.
    let undoTimelineStore: UndoTimelineStore
    var perFileUndoTimelines: [String: DocumentUndoTimeline] {
        get { undoTimelineStore.timelines }
        _modify { yield &undoTimelineStore.timelines }
    }
    var hasUnpersistedUndoChanges: Bool = false
    public var currentSelectedRange: NSRange = NSRange(location: 0, length: 0)
    var isApplyingInternalStateChange: Bool = false
    var pendingEditOrigin: UndoEntryOrigin = .userTyping
    var pendingEditSummary: String?
    var canCoalesceLiveTyping: Bool = false
    public var isLiveKeystrokeInProgress: Bool = false
    var recentSelfWrites = SelfWriteHistory()
    /// Seconds without edits before autosave writes the file. 0 saves on every edit.
    public var autoSaveDelay: TimeInterval = 1.0
    var pendingAutoSaveWorkItem: DispatchWorkItem?
    /// Persistence work counts, read by the perf invariant tests.
    var perfCounters = WorkspacePerfCounters()
    var pendingRemoteUploads: [URL: String] = [:]
    var remoteUploadsInFlight: Set<URL> = []
    nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    // MARK: - Editor Modes, Theme & Typography
    var isSyncingThemeTypography: Bool = false

    @Published public var customThemes: [EditorTheme] = [] {
        didSet {
            guard !isRestoringState else { return }
            if let encoded = try? JSONEncoder().encode(customThemes) {
                userDefaults.set(encoded, forKey: Self.customThemesDefaultsKey)
            }
            sharePreference(\.customThemes)
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
            sharePreference(\.theme)
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
            sharePreference(\.typography)
        }
    }
    @Published public var sourceCodeMode: Bool = false {
        didSet { if !isRestoringState { userDefaults.set(sourceCodeMode, forKey: Self.sourceCodeModeDefaultsKey); sharePreference(\.sourceCodeMode) } }
    }
    @Published public var prettyModeEnabled: Bool = true
    @Published public var focusMode: Bool = false {
        didSet { if !isRestoringState { userDefaults.set(focusMode, forKey: Self.focusModeDefaultsKey); sharePreference(\.focusMode) } }
    }
    @Published public var typewriterMode: Bool = false {
        didSet { if !isRestoringState { userDefaults.set(typewriterMode, forKey: Self.typewriterModeDefaultsKey); sharePreference(\.typewriterMode) } }
    }
    @Published public var spellCheckEnabled: Bool = false {
        didSet { if !isRestoringState { userDefaults.set(spellCheckEnabled, forKey: Self.spellCheckEnabledDefaultsKey); sharePreference(\.spellCheckEnabled) } }
    }
    /// Column width that edited paragraphs are hard-wrapped to in the Markdown source (0 = off).
    @Published public var sourceLineWidth: Int = MarkdownSourceReflow.defaultWidth {
        didSet { if !isRestoringState { userDefaults.set(sourceLineWidth, forKey: Self.sourceLineWidthDefaultsKey); sharePreference(\.sourceLineWidth) } }
    }
    /// Editor-wide alignment for prose.
    @Published public var textAlignment: EditorTextAlignment = .left {
        didSet { if !isRestoringState { userDefaults.set(textAlignment.rawValue, forKey: Self.textAlignmentDefaultsKey); sharePreference(\.textAlignment) } }
    }
    /// Mermaid diagram shown in the pan-and-zoom sheet.
    @Published public var expandedDiagram: ExpandedDiagram?
    /// Paper size used by Print.
    @Published public var printPaperSize: PrintPaperSize = .letter {
        didSet { if !isRestoringState { userDefaults.set(printPaperSize.rawValue, forKey: Self.printPaperSizeDefaultsKey); sharePreference(\.printPaperSize) } }
    }
    /// Page orientation used by Print (unless overridden in the document).
    @Published public var printOrientation: PrintOrientation = .portrait {
        didSet {
            guard !isRestoringState else { return }
            userDefaults.set(printOrientation.rawValue, forKey: Self.printOrientationDefaultsKey)
            sharePreference(\.printOrientation)
        }
    }
    /// Page margins used by Print (unless overridden in the document).
    @Published public var printMargins: PrintPageMargins = .default {
        didSet {
            guard !isRestoringState else { return }
            if let encoded = try? JSONEncoder().encode(printMargins) {
                userDefaults.set(encoded, forKey: Self.printMarginsDefaultsKey)
            }
            sharePreference(\.printMargins)
        }
    }
    /// Custom `curl` command prefix used to fetch remote media URLs (e.g. `curl -b "session=..."`).
    @Published public var mediaCurlCommandPrefix: String = FolioMediaImageCache.defaultCurlCommandPrefix {
        didSet {
            FolioMediaImageCache.shared.curlCommandPrefix = mediaCurlCommandPrefix
            guard !isRestoringState else { return }
            userDefaults.set(mediaCurlCommandPrefix, forKey: Self.mediaCurlCommandPrefixDefaultsKey)
            sharePreference(\.mediaCurlCommandPrefix)
        }
    }
    /// When enabled, passes Remote Host Access SSH credentials (`--key` and `-u`) to `curl`.
    @Published public var useSSHAuthForMedia: Bool = false {
        didSet {
            syncMediaSSHAuthConfig()
            guard !isRestoringState else { return }
            userDefaults.set(useSSHAuthForMedia, forKey: Self.mediaUseSSHAuthDefaultsKey)
            sharePreference(\.useSSHAuthForMedia)
        }
    }
    /// Optional SSH identity key path (`--key`) for remote media; defaults to the connected Remote Mount's key or `~/.ssh`.
    @Published public var mediaSSHIdentityFile: String = "" {
        didSet {
            syncMediaSSHAuthConfig()
            guard !isRestoringState else { return }
            userDefaults.set(mediaSSHIdentityFile, forKey: Self.mediaSSHIdentityFileDefaultsKey)
            sharePreference(\.mediaSSHIdentityFile)
        }
    }
    /// Optional SSH username (`-u <user>:`) for remote media; defaults to the connected Remote Mount's user.
    @Published public var mediaSSHUser: String = "" {
        didSet {
            syncMediaSSHAuthConfig()
            guard !isRestoringState else { return }
            userDefaults.set(mediaSSHUser, forKey: Self.mediaSSHUserDefaultsKey)
            sharePreference(\.mediaSSHUser)
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
    @Published public var fileFilterText: String = ""

    // MARK: - Modals & Banners
    @Published public var showQuickOpen: Bool = false
    @Published public var quickOpenQuery: String = "" {
        didSet {
            if quickOpenQuery != oldValue {
                quickOpenSelectedIndex = 0
            }
        }
    }
    @Published public var quickOpenSelectedIndex: Int = 0
    @Published public var showWordCountPopover: Bool = false
    @Published public var showInsertTableSheet: Bool = false
    @Published public var showSettingsModal: Bool = false
    @Published public var showFindReplaceBar: Bool = false
    @Published public var showDocumentReplaceControls: Bool = false
    @Published public var findBarFocusRequestID: Int = 0
    @Published public var showAddRemoteModal: Bool = false
    @Published public var findQuery: String = ""
    @Published public var replaceQuery: String = ""

    // MARK: - Outline & Statistics
    @Published public var headings: [OutlineHeading] = []
    @Published public var activeHeadingID: String?
    @Published public var stats: DocumentStats = DocumentStats()
    @Published public var pendingScrollToCharacterLocation: Int?

    // MARK: - Selection Tooltip & Companion Comments
    @Published public var selectionComments: [SelectionComment] = []
    @Published public var activeCommentID: UUID?
    @Published public var showCommentsSidebar: Bool = true
    @Published public var activeCommentDraftRange: NSRange?
    @Published public var activeCommentDraftText: String = ""
    @Published public var selectionTooltipAnchor: SelectionTooltipAnchor?
    public var currentSelectionDirection: SelectionDirection = .forward

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
            sharePreference(\.recentFileURLs)
        }
    }

    // MARK: - Remote Folders & Files (SSH / SFTP Multi-Root Sync)
    public let remoteWorkspaceManager: RemoteWorkspaceManager
    public let userDefaults: UserDefaults
    @Published public var remoteConnectionBannerDismissed: Bool = false
    var cancellables: Set<AnyCancellable> = []
    var isRestoringState: Bool = true

    @Published public var workspaceSearchQuery: String = ""
    @Published public var workspaceReplaceQuery: String = ""
    @Published public var showWorkspaceReplace: Bool = false
    @Published public var workspaceSearchFocusRequestID: Int = 0
    @Published public var searchCaseSensitive: Bool = false
    @Published public var searchWholeWord: Bool = false
    @Published public var searchUseRegex: Bool = false
    @Published public var workspaceSearchMatches: [WorkspaceSearchMatch] = []

    public weak var activeTextView: HybridMarkdownTextView?

    // MARK: - Document Window
    /// This view model's window. Nil in single-window mode.
    public let documentWindow: DocumentWindowContext?
    weak var windowRegistry: DocumentWindowRegistry?
    public weak var hostWindow: NSWindow?
    /// True while this window is the one the app menus act on.
    @Published public internal(set) var isActiveDocumentWindow: Bool = false
    var isApplyingSharedPreference: Bool = false

    nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) var parentDirWatchSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) var fileWatchDescriptor: Int32 = -1
    nonisolated(unsafe) var parentDirWatchDescriptor: Int32 = -1
    nonisolated(unsafe) var watchedFileInode: UInt64 = 0
    nonisolated(unsafe) var externalHighlightClearTask: Task<Void, Never>?

    public init(
        remoteWorkspaceManager: RemoteWorkspaceManager? = nil,
        userDefaults: UserDefaults? = nil,
        documentWindow: DocumentWindowContext? = nil,
        windowRegistry: DocumentWindowRegistry? = nil
    ) {
        let resolvedDefaults = userDefaults ?? remoteWorkspaceManager?.userDefaults ?? .standard
        let manager = remoteWorkspaceManager ?? RemoteWorkspaceManager(userDefaults: resolvedDefaults)
        self.userDefaults = resolvedDefaults
        self.remoteWorkspaceManager = manager
        self.documentWindow = documentWindow
        self.windowRegistry = windowRegistry
        self.undoTimelineStore = windowRegistry?.undoTimelineStore ?? UndoTimelineStore()
        self.markdownText = Self.defaultWelcomeDocument
        restoreStateOnInit(resolvedDefaults: resolvedDefaults, manager: manager)
        observeTerminationForPendingAutoSave()
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        externalHighlightClearTask?.cancel()
        stopWatchingCurrentFile()
    }
}
