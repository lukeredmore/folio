import AppKit
import Foundation

/// What a document window opens with. `nil` on the view model means single-window mode,
/// which reads and writes the original global session keys.
public struct DocumentWindowContext: Sendable {
    public let id: String
    public let initialFileURL: URL?
    public let initialWorkspaceURL: URL?
    /// True for the first window of a launch: with no saved session of its own,
    /// it restores the global session from earlier launches.
    public let adoptsLegacySession: Bool

    public init(id: String, initialFileURL: URL?, initialWorkspaceURL: URL?, adoptsLegacySession: Bool) {
        self.id = id
        self.initialFileURL = initialFileURL
        self.initialWorkspaceURL = initialWorkspaceURL
        self.adoptsLegacySession = adoptsLegacySession
    }
}

/// Where a window reads its document session from at launch.
enum DocumentSessionSource {
    /// This window's own keys, from an earlier run of the same window.
    case window
    /// The global keys, which hold the last active window's session.
    case legacy
    /// Nothing: a new tab, which opens `initialFileURL` or an untitled buffer.
    case none
}

extension EditorWorkspaceViewModel {

    static let untitledDocumentTemplate = "# Untitled\n\n"

    /// True when this window may show sheets that belong to the whole app, such as Software Update.
    public var presentsAppWideSheets: Bool {
        documentWindow == nil || isActiveDocumentWindow
    }

    // MARK: - Session Keys

    /// The defaults key that stores `base` for this window.
    func windowSessionKey(_ base: String) -> String {
        guard let id = documentWindow?.id else { return base }
        return "\(base).\(id)"
    }

    /// Writes this window's session value. The active window also writes the global key,
    /// so a launch without restored windows reopens the last document in use.
    func setSessionValue(_ value: Any?, forKey base: String) {
        Self.write(value, forKey: windowSessionKey(base), in: userDefaults)
        if documentWindow != nil && isActiveDocumentWindow {
            Self.write(value, forKey: base, in: userDefaults)
        }
    }

    private static func write(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func resolveDocumentSessionSource(in defaults: UserDefaults) -> DocumentSessionSource {
        guard let context = documentWindow else { return .legacy }
        if defaults.bool(forKey: windowSessionKey(Self.hasSavedDocumentSessionDefaultsKey)) { return .window }
        if context.initialFileURL != nil { return .none }
        return context.adoptsLegacySession ? .legacy : .none
    }

    /// The key to read `base` from at launch, or nil when `source` has no saved session.
    func sessionReadKey(_ base: String, source: DocumentSessionSource) -> String? {
        switch source {
        case .window: return windowSessionKey(base)
        case .legacy: return base
        case .none: return nil
        }
    }

    static let windowScopedSessionKeys = [
        currentFilePathDefaultsKey,
        currentFileBookmarkDefaultsKey,
        unsavedBufferTextDefaultsKey,
        unsavedBufferIsDirtyDefaultsKey,
        hasSavedDocumentSessionDefaultsKey,
        selectedCursorLocationDefaultsKey,
        workspaceFolderPathDefaultsKey,
        workspaceFolderBookmarkDefaultsKey,
    ]

    // MARK: - Window Lifecycle

    /// Marks this window as the one the app menus and global session keys follow.
    func setActiveDocumentWindow(_ isActive: Bool) {
        guard isActiveDocumentWindow != isActive else { return }
        isActiveDocumentWindow = isActive
        guard isActive, !isRestoringState else { return }
        persistWorkspaceFolder(workspaceFolderURL)
        persistCurrentFileBookmark()
        persistDocumentSessionState()
    }

    /// Saves pending edits and deletes this window's session keys after the user closes the window.
    func closeDocumentWindowSession(isTerminating: Bool) {
        flushPendingAutoSave()
        if hasUnpersistedUndoChanges { persistUndoTimelines() }
        guard !isTerminating else { return }
        discardUntouchedNewFile()
        stopWatchingCurrentFile()
        guard documentWindow != nil else { return }
        for base in Self.windowScopedSessionKeys {
            userDefaults.removeObject(forKey: windowSessionKey(base))
        }
    }

    // MARK: - Tabs

    /// Opens `url`, or an untitled buffer, in a new tab of this window.
    /// A file can be open in several tabs; they stay in sync through `syncFromSiblingTab`.
    public func openInNewTab(_ url: URL?) {
        guard let registry = windowRegistry else {
            if let url { openFile(at: url) } else { newDocument() }
            return
        }
        registry.openInNewTab(fileURL: url, from: self)
    }

    // MARK: - Same File in Several Tabs

    /// Applies text that another tab just wrote to the file this tab shows.
    /// A tab without unsaved edits takes the text as-is: no undo step and no update banner,
    /// because the tabs share the file's undo history. Unsaved edits go through the normal merge.
    func syncFromSiblingTab(wrote content: String, to url: URL) {
        guard currentFileURL?.standardizedFileURL == url.standardizedFileURL else { return }
        if markdownText == content {
            lastSavedDiskContent = content
            isDirty = false
            return
        }
        guard activeConflict == nil, markdownText == lastSavedDiskContent, !hasPendingAutoSave else {
            handleExternalFileUpdate(diskContent: content, for: url, sourceDescription: "Another Tab")
            return
        }
        let selection = DocumentLineDiff.adjustedSelection(
            for: currentSelectedRange,
            inOldText: markdownText,
            toNewText: content
        )
        isApplyingInternalStateChange = true
        markdownText = content
        lastSavedDiskContent = content
        isDirty = false
        currentSelectedRange = selection
        isApplyingInternalStateChange = false
        stats = DocumentStats.compute(for: content, selectedRange: selection)
        if let textView = activeTextView {
            textView.applyProgrammaticDocumentText(content, selectedRange: selection)
        } else {
            headings = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: content),
                theme: theme,
                typography: typography,
                sourceCodeMode: sourceCodeMode,
                focusMode: focusMode,
                selectedRange: selection,
                baseDirectoryURL: url.deletingLastPathComponent(),
                fileURL: url
            ).headings
        }
        refreshUndoRedoAvailability()
        persistDocumentSessionState()
    }

    /// Reloads text and comments from disk when this tab is selected, if another tab shows the same file.
    /// Comments are saved without a text write, so `syncFromSiblingTab` alone would miss them.
    func refreshFromSiblingTabs() {
        guard let url = currentFileURL, let registry = windowRegistry,
              registry.viewModels.contains(where: { $0 !== self && $0.isShowing(url) }),
              activeConflict == nil, markdownText == lastSavedDiskContent, !hasPendingAutoSave,
              let diskContent = try? String(contentsOf: url, encoding: .utf8) else { return }
        syncFromSiblingTab(wrote: diskContent, to: url)
        let showsSidebar = showCommentsSidebar
        let selectedComment = activeCommentID
        loadCompanionComments(for: url, documentText: markdownText)
        showCommentsSidebar = showsSidebar
        if selectionComments.contains(where: { $0.id == selectedComment }) { activeCommentID = selectedComment }
    }

    func isShowing(_ url: URL) -> Bool {
        currentFileURL?.standardizedFileURL == url.standardizedFileURL
    }

    // MARK: - App-Wide Preferences

    /// Copies a preference that this window just changed to every other open window.
    func sharePreference<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<EditorWorkspaceViewModel, Value>) {
        guard !isRestoringState, !isApplyingSharedPreference, let registry = windowRegistry else { return }
        let value = self[keyPath: keyPath]
        for other in registry.viewModels where other !== self && other[keyPath: keyPath] != value {
            other.isApplyingSharedPreference = true
            other[keyPath: keyPath] = value
            other.isApplyingSharedPreference = false
        }
    }
}
