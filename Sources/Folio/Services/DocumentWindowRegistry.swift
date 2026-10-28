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
    var openWindowAction: OpenWindowAction?
    /// True after the user quits, so closing windows keeps their sessions for the next launch.
    public var isTerminating = false

    private struct Entry {
        weak var viewModel: EditorWorkspaceViewModel?
        weak var window: NSWindow?
        var observers: [NSObjectProtocol] = []
    }

    private struct WeakWindow { weak var window: NSWindow? }

    private var entries: [UUID: Entry] = [:]
    private var pendingTabParents: [UUID: WeakWindow] = [:]
    private var pendingOpenPaths: [String] = []
    private var hasCreatedViewModel = false
    private var hasPerformedLaunchSetup = false

    public init(userDefaults: UserDefaults = .standard, remoteWorkspaceManager: RemoteWorkspaceManager? = nil) {
        self.userDefaults = userDefaults
        self.remoteWorkspaceManager = remoteWorkspaceManager ?? RemoteWorkspaceManager(userDefaults: userDefaults)
    }

    public var viewModels: [EditorWorkspaceViewModel] {
        entries.values.compactMap(\.viewModel)
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
    func attach(_ window: NSWindow, to viewModel: EditorWorkspaceViewModel) {
        guard let id = windowID(of: viewModel), entries[id]?.window !== window else { return }
        entries[id]?.observers.forEach(NotificationCenter.default.removeObserver)
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
        if !pendingOpenPaths.isEmpty { openPaths([]) }
    }

    private func windowWillClose(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.observers.forEach(NotificationCenter.default.removeObserver)
        guard let viewModel = entry.viewModel else { return }
        viewModel.closeDocumentWindowSession(isTerminating: isTerminating)
        if activeViewModel === viewModel {
            activeViewModel = nil
            if let next = viewModels.first { setActive(next) }
        }
    }

    /// Returns true once per launch, for the first window that appears, and makes that window active.
    func claimLaunchSetup(for viewModel: EditorWorkspaceViewModel) -> Bool {
        guard !hasPerformedLaunchSetup else { return false }
        hasPerformedLaunchSetup = true
        if activeViewModel == nil { setActive(viewModel) }
        return true
    }

    // MARK: - Opening Files

    /// Opens CLI or Finder paths in the active window, or queues them until a window exists.
    public func openPaths(_ paths: [String]) {
        guard !paths.isEmpty || !pendingOpenPaths.isEmpty else { return }
        guard let viewModel = activeViewModel else {
            pendingOpenPaths.append(contentsOf: paths)
            openWindowForPendingPathsIfNeeded()
            return
        }
        let queued = pendingOpenPaths
        pendingOpenPaths.removeAll()
        viewModel.openPathsFromCLI(FolioCLIManager.deduplicateCommandLinePaths(queued + paths))
    }

    /// SwiftUI creates no default window when the app launches to open files, so open one for them.
    /// The delay lets restored windows appear first; the first window drains the queue when it becomes active.
    private func openWindowForPendingPathsIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.pendingOpenPaths.isEmpty, self.viewModels.isEmpty,
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
