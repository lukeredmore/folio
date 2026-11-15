import AppKit
import SwiftUI

/// Tracks every open document window and the state that all of them share.
///
/// Each window or tab owns one `EditorWorkspaceViewModel`. The registry knows which window is
/// active, routes files opened from the CLI or Finder to it, and opens files in new tabs.
@MainActor
public final class DocumentWindowRegistry: ObservableObject {
    public static let shared = DocumentWindowRegistry()

    public let userDefaults: UserDefaults
    public let remoteWorkspaceManager: RemoteWorkspaceManager
    public let undoTimelineStore = UndoTimelineStore()
    /// The window that the app menus act on: the key window, or the last one that was key.
    @Published public private(set) var activeViewModel: EditorWorkspaceViewModel?
    /// Set from a SwiftUI view, because `openWindow` is only available in the view environment.
    package var openWindowAction: OpenWindowAction?
    /// True after the user quits, so closing windows keeps their sessions for the next launch.
    public var isTerminating = false

    private struct Entry {
        weak var viewModel: EditorWorkspaceViewModel?
        /// Retains programmatically opened tab view models until SwiftUI mounts their window and attaches `NSWindow`.
        var pendingRetainedViewModel: EditorWorkspaceViewModel?
        weak var window: NSWindow?
        var observers: [NSObjectProtocol] = []
    }

    private struct WeakWindow { weak var window: NSWindow? }

    private struct WaitTarget {
        weak var viewModel: EditorWorkspaceViewModel?
        /// Canonical file URL waited on, or `nil` when waiting on a workspace folder window/tab.
        let waitedFileURL: URL?
    }

    private struct WaitSession {
        let tokenPath: String
        var targets: [WaitTarget]
    }

    private var entries: [UUID: Entry] = [:]
    private var pendingTabParents: [UUID: WeakWindow] = [:]
    private var pendingOpenRequests: [FolioCLIOpenRequest] = []
    private var waitSessions: [WaitSession] = []
    private var hasCreatedViewModel = false
    private var hasPerformedLaunchSetup = false

    public init(userDefaults: UserDefaults = .standard, remoteWorkspaceManager: RemoteWorkspaceManager? = nil) {
        self.userDefaults = userDefaults
        self.remoteWorkspaceManager = remoteWorkspaceManager ?? RemoteWorkspaceManager(userDefaults: userDefaults)
    }

    public var viewModels: [EditorWorkspaceViewModel] {
        entries.values.compactMap(\.viewModel)
    }

    public var activeWaitTokenPaths: [String] {
        waitSessions.map(\.tokenPath)
    }

    // MARK: - Window Lifecycle

    /// Creates the view model for a window. The first window of a launch restores the global session.
    public func makeViewModel(for value: DocumentWindowValue) -> EditorWorkspaceViewModel {
        if let existing = entries[value.id]?.viewModel { return existing }
        let context = DocumentWindowContext(
            id: value.id.uuidString,
            initialFileURL: value.initialFileURL,
            initialWorkspaceURL: value.initialWorkspaceURL ?? activeViewModel?.workspaceFolderURL,
            adoptsLegacySession: !hasCreatedViewModel
        )
        hasCreatedViewModel = true
        let viewModel = EditorWorkspaceViewModel(
            remoteWorkspaceManager: remoteWorkspaceManager,
            userDefaults: userDefaults,
            documentWindow: context,
            windowRegistry: self
        )
        entries[value.id] = Entry(viewModel: viewModel)
        if let url = value.initialFileURL { viewModel.addRecentFile(url) }
        return viewModel
    }

    /// Connects a view model to its `NSWindow`, and tabs a requested new tab into its opener.
    package func attach(_ window: NSWindow, to viewModel: EditorWorkspaceViewModel) {
        guard let id = windowID(of: viewModel), entries[id]?.window !== window else { return }
        if let existingObservers = entries[id]?.observers {
            for observer in existingObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        viewModel.hostWindow = window
        let center = NotificationCenter.default
        let becameKey = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self, weak viewModel] _ in
            MainActor.assumeIsolated {
                if let viewModel { self?.setActive(viewModel) }
            }
        }
        let willClose = center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose(id) }
        }
        entries[id]?.pendingRetainedViewModel = nil
        entries[id]?.window = window
        entries[id]?.observers = [becameKey, willClose]

        if let parent = pendingTabParents.removeValue(forKey: id)?.window, parent !== window,
            parent.tabGroup?.windows.contains(window) != true
        {
            parent.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        if window.isKeyWindow {
            // Deferred: this runs inside a SwiftUI view update, where publishing changes is not allowed.
            DispatchQueue.main.async { [weak self, weak viewModel] in
                if let viewModel { self?.setActive(viewModel) }
            }
        }
    }

    private func windowID(of viewModel: EditorWorkspaceViewModel) -> UUID? {
        entries.first { $0.value.viewModel === viewModel }?.key
    }

    private func setActive(_ viewModel: EditorWorkspaceViewModel) {
        guard activeViewModel !== viewModel else { return }
        // Save the tab being left first, so a tab on the same file opens with its latest text.
        activeViewModel?.flushPendingAutoSave()
        activeViewModel?.setActiveDocumentWindow(false)
        activeViewModel = viewModel
        viewModel.setActiveDocumentWindow(true)
        viewModel.refreshFromSiblingTabs()
        if !pendingOpenRequests.isEmpty { openRequests([]) }
    }

    public func closeWindow(for viewModel: EditorWorkspaceViewModel) {
        guard let id = windowID(of: viewModel) else {
            viewModel.closeDocumentWindowSession(isTerminating: isTerminating)
            completeWaitTargets(forClosedViewModel: viewModel)
            return
        }
        if let window = entries[id]?.window {
            window.close()
        }
        if entries[id] != nil {
            windowWillClose(id)
        }
    }

    private func windowWillClose(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        for observer in entry.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let viewModel = entry.viewModel else {
            pruneAndCompleteWaitSessions()
            return
        }
        viewModel.closeDocumentWindowSession(isTerminating: isTerminating)
        completeWaitTargets(forClosedViewModel: viewModel)
        if activeViewModel === viewModel {
            activeViewModel = nil
            if let next = viewModels.first { setActive(next) }
        }
    }

    /// Flushes all pending autosaves to disk and completes any active `--wait` CLI sessions before termination.
    public func prepareForTermination() {
        isTerminating = true
        for viewModel in viewModels {
            viewModel.flushPendingAutoSaveForTermination()
        }
        let pendingTokens = pendingOpenRequests.compactMap(\.waitTokenPath)
        pendingOpenRequests.removeAll()
        let activeTokens = waitSessions.map(\.tokenPath)
        waitSessions.removeAll()
        for tokenPath in activeTokens + pendingTokens {
            Self.unlinkWaitTokenFile(atPath: tokenPath)
        }
    }

    /// Returns true once per launch, for the first window that appears, and makes that window active.
    package func claimLaunchSetup(for viewModel: EditorWorkspaceViewModel) -> Bool {
        guard !hasPerformedLaunchSetup else { return false }
        hasPerformedLaunchSetup = true
        if activeViewModel == nil { setActive(viewModel) }
        return true
    }

    // MARK: - Opening Files & CLI `--wait` Sessions

    /// Opens CLI or Finder paths in the active window, or queues them until a window exists.
    public func openPaths(_ paths: [String]) {
        if paths.isEmpty {
            openRequests([])
        } else {
            openRequests([FolioCLIOpenRequest(paths: paths)])
        }
    }

    /// Opens CLI requests (including `--wait` requests tracked by wait-token files) or queues them until a window exists.
    public func openRequests(_ requests: [FolioCLIOpenRequest]) {
        let mergedIncoming = FolioCLIManager.mergeOpenRequests(requests)
        guard !mergedIncoming.isEmpty || !pendingOpenRequests.isEmpty else { return }
        guard activeViewModel != nil else {
            pendingOpenRequests = FolioCLIManager.mergeOpenRequests(pendingOpenRequests + mergedIncoming)
            openWindowForPendingPathsIfNeeded()
            return
        }
        let toProcess = FolioCLIManager.mergeOpenRequests(pendingOpenRequests + mergedIncoming)
        pendingOpenRequests.removeAll()
        for request in toProcess {
            if let waitTokenPath = request.waitTokenPath {
                openWaitedRequest(paths: request.paths, waitTokenPath: waitTokenPath)
            } else if let viewModel = activeViewModel {
                viewModel.openPathsFromCLI(FolioCLIManager.deduplicateCommandLinePaths(request.paths))
            }
        }
    }

    private func openWaitedRequest(paths: [String], waitTokenPath: String) {
        let rawPaths = FolioCLIManager.deduplicateCommandLinePaths(paths)
        guard !rawPaths.isEmpty, let initialActive = activeViewModel else {
            Self.unlinkWaitTokenFile(atPath: waitTokenPath)
            return
        }

        var targets: [WaitTarget] = []
        var usedUntouchedActiveWindowForFolder = false

        for rawPath in rawPaths {
            let resolver = activeViewModel ?? initialActive
            guard let candidate = resolver.resolveCLIPathCandidate(for: rawPath) else { continue }

            if candidate.exists && candidate.isDirectory {
                if let active = activeViewModel,
                    active.currentFileURL == nil && !active.isDirty && !usedUntouchedActiveWindowForFolder
                {
                    usedUntouchedActiveWindowForFolder = true
                    active.openPathFromCLI(rawPath)
                    targets.append(WaitTarget(viewModel: active, waitedFileURL: nil))
                } else {
                    let tabViewModel = openCLIPathInNewTab(rawPath, from: resolver)
                    targets.append(WaitTarget(viewModel: tabViewModel, waitedFileURL: nil))
                }
            } else {
                let targetCanonicalURL = Self.canonicalFileURL(candidate.url)
                if let existing = viewModels.first(where: { $0.currentFileURL.map(Self.canonicalFileURL) == targetCanonicalURL }) {
                    setActive(existing)
                    existing.hostWindow?.makeKeyAndOrderFront(nil)
                    if let line = candidate.lineNumber, line >= 1 {
                        existing.navigateToLineNumber(line, columnNumber: candidate.columnNumber)
                    }
                    targets.append(WaitTarget(viewModel: existing, waitedFileURL: targetCanonicalURL))
                } else if let active = activeViewModel,
                    active.currentFileURL == nil && !active.isDirty && !usedUntouchedActiveWindowForFolder
                {
                    active.openPathFromCLI(rawPath)
                    if let openedURL = active.currentFileURL {
                        targets.append(WaitTarget(viewModel: active, waitedFileURL: Self.canonicalFileURL(openedURL)))
                    }
                } else {
                    let tabViewModel = openCLIPathInNewTab(rawPath, from: resolver)
                    if let openedURL = tabViewModel.currentFileURL {
                        targets.append(WaitTarget(viewModel: tabViewModel, waitedFileURL: Self.canonicalFileURL(openedURL)))
                    }
                }
            }
        }

        guard !targets.isEmpty else {
            Self.unlinkWaitTokenFile(atPath: waitTokenPath)
            return
        }
        if let existingIndex = waitSessions.firstIndex(where: { $0.tokenPath == waitTokenPath }) {
            waitSessions[existingIndex].targets.append(contentsOf: targets)
        } else {
            waitSessions.append(WaitSession(tokenPath: waitTokenPath, targets: targets))
        }
    }

    private func openCLIPathInNewTab(_ rawPath: String, from source: EditorWorkspaceViewModel) -> EditorWorkspaceViewModel {
        source.flushPendingAutoSave()
        let value = DocumentWindowValue(initialWorkspaceURL: source.workspaceFolderURL)
        if let parent = source.hostWindow {
            pendingTabParents[value.id] = WeakWindow(window: parent)
        }
        let tabViewModel = makeViewModel(for: value)
        entries[value.id]?.pendingRetainedViewModel = tabViewModel
        tabViewModel.openPathFromCLI(rawPath)
        setActive(tabViewModel)
        openWindowAction?(value: value)
        return tabViewModel
    }

    func viewModelDidChangeCurrentFile(_ viewModel: EditorWorkspaceViewModel, to newFileURL: URL?) {
        let currentCanonical = newFileURL.map(Self.canonicalFileURL)
        updateWaitSessions { target in
            guard target.viewModel === viewModel, let waitedURL = target.waitedFileURL else { return false }
            return currentCanonical != waitedURL
        }
    }

    private func completeWaitTargets(forClosedViewModel closedViewModel: EditorWorkspaceViewModel) {
        updateWaitSessions { $0.viewModel === closedViewModel }
    }

    private func pruneAndCompleteWaitSessions() {
        updateWaitSessions { _ in false }
    }

    private func updateWaitSessions(_ shouldRemoveTarget: (WaitTarget) -> Bool) {
        var completedTokens: [String] = []
        var index = 0
        while index < waitSessions.count {
            waitSessions[index].targets.removeAll { target in
                guard target.viewModel != nil else { return true }
                return shouldRemoveTarget(target)
            }
            if waitSessions[index].targets.isEmpty {
                completedTokens.append(waitSessions[index].tokenPath)
                waitSessions.remove(at: index)
            } else {
                index += 1
            }
        }
        for tokenPath in completedTokens {
            Self.unlinkWaitTokenFile(atPath: tokenPath)
        }
    }

    private static func unlinkWaitTokenFile(atPath path: String) {
        guard !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        return
            url
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
    }

    /// SwiftUI creates no default window when the app launches to open files, so open one for them.
    /// The delay lets restored windows appear first; the first window drains the queue when it becomes active.
    private func openWindowForPendingPathsIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.pendingOpenRequests.isEmpty, self.viewModels.isEmpty,
                let openWindow = self.openWindowAction
            else { return }
            openWindow(value: DocumentWindowValue())
        }
    }

    /// Opens `fileURL` (or an untitled buffer) in a new tab of `source`'s window.
    func openInNewTab(fileURL: URL?, from source: EditorWorkspaceViewModel) {
        guard let openWindow = openWindowAction else {
            if let fileURL { source.openFile(at: fileURL) } else { source.newDocument() }
            return
        }
        source.flushPendingAutoSave()
        let value = DocumentWindowValue(initialFileURL: fileURL, initialWorkspaceURL: source.workspaceFolderURL)
        if let parent = source.hostWindow {
            pendingTabParents[value.id] = WeakWindow(window: parent)
        }
        openWindow(value: value)
    }

    /// Passes a save in one tab to the other tabs that show the same file.
    func fileWasWritten(_ url: URL, content: String, by writer: EditorWorkspaceViewModel) {
        for viewModel in viewModels where viewModel !== writer && viewModel.isShowing(url) {
            viewModel.syncFromSiblingTab(wrote: content, to: url)
        }
    }

}
