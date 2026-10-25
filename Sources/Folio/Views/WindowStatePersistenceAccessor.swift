import AppKit
import SwiftUI

final class PassThroughAccessorNSView: NSView {
    var onMoveToWindow: ((NSWindow) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window { onMoveToWindow?(window) }
    }
}

struct WindowStatePersistenceAccessor: NSViewRepresentable {
    let viewModel: EditorWorkspaceViewModel
    let showSidebar: Bool
    @Binding var columnVisibility: NavigationSplitViewVisibility
    static let windowFrameDefaultsKey = "Folio.MainWindowFrame.v1"

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, columnVisibility: $columnVisibility)
    }

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        let coordinator = context.coordinator
        view.onMoveToWindow = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.columnVisibility = $columnVisibility
        if let window = nsView.window {
            if context.coordinator.attachedWindow !== window {
                context.coordinator.attach(to: window)
            } else {
                context.coordinator.configureWindowAppearance(window)
                context.coordinator.bindSplitViewIfNeeded(in: window)
                context.coordinator.applySidebarVisibilityIfNeeded(showSidebar)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var viewModel: EditorWorkspaceViewModel?
        var columnVisibility: Binding<NavigationSplitViewVisibility>
        let userDefaults: UserDefaults
        weak var attachedWindow: NSWindow?
        weak var observedSplitView: NSSplitView?
        var sidebarCollapsedObservation: NSKeyValueObservation?
        var lastAppliedShowSidebar: Bool?

        init(viewModel: EditorWorkspaceViewModel, columnVisibility: Binding<NavigationSplitViewVisibility>) {
            self.viewModel = viewModel
            self.columnVisibility = columnVisibility
            self.userDefaults = viewModel.userDefaults
        }

        deinit {
            sidebarCollapsedObservation?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }

        func configureWindowAppearance(_ window: NSWindow) {
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
        }

        static func isRestorableWindowFrame(_ rect: NSRect, for window: NSWindow) -> Bool {
            guard rect.width >= 720, rect.height >= 480 else { return false }
            if let screen = window.screen ?? NSScreen.main {
                if rect.width >= screen.frame.width && rect.height >= screen.visibleFrame.height {
                    return false
                }
            }
            return true
        }

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            if let oldWindow = attachedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: oldWindow)
            }
            attachedWindow = window
            configureWindowAppearance(window)

            if !window.styleMask.contains(.fullScreen),
               let savedFrameString = userDefaults.string(forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey) {
                let rect = NSRectFromString(savedFrameString)
                if Self.isRestorableWindowFrame(rect, for: window) {
                    window.setFrame(rect, display: true)
                } else {
                    userDefaults.removeObject(forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey)
                }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeFrame(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeFrame(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidTransitionFullScreen(_:)),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidTransitionFullScreen(_:)),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )

            bindSplitViewIfNeeded(in: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.bindSplitViewIfNeeded(in: window)
                self.reconcileSidebarWithModel(in: window)
            }
        }

        func bindSplitViewIfNeeded(in window: NSWindow) {
            guard let splitView = Self.findSplitView(in: window.contentView?.superview),
                  let svc = splitView.delegate as? NSSplitViewController,
                  let sidebarItem = svc.splitViewItems.first else {
                return
            }
            if splitView.autosaveName != nil {
                splitView.autosaveName = nil
            }
            guard observedSplitView !== splitView else { return }
            observedSplitView = splitView
            reconcileSidebarWithModel(in: window)

            sidebarCollapsedObservation?.invalidate()
            sidebarCollapsedObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                let isCollapsed = item.isCollapsed
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncModelAndVisibility(isSidebarVisible: !isCollapsed)
                }
            }
        }

        func reconcileSidebarWithModel(in window: NSWindow) {
            guard let splitView = Self.findSplitView(in: window.contentView?.superview),
                  let svc = splitView.delegate as? NSSplitViewController,
                  let sidebarItem = svc.splitViewItems.first,
                  let vm = viewModel else {
                return
            }
            lastAppliedShowSidebar = vm.showSidebar
            if sidebarItem.isCollapsed != !vm.showSidebar {
                sidebarItem.isCollapsed = !vm.showSidebar
            }
            let targetVisibility: NavigationSplitViewVisibility = vm.showSidebar ? .all : .detailOnly
            if columnVisibility.wrappedValue != targetVisibility {
                columnVisibility.wrappedValue = targetVisibility
            }
        }

        func syncModelAndVisibility(isSidebarVisible: Bool) {
            lastAppliedShowSidebar = isSidebarVisible
            if let vm = viewModel, vm.showSidebar != isSidebarVisible {
                vm.showSidebar = isSidebarVisible
            }
            if isSidebarVisible {
                if columnVisibility.wrappedValue == .detailOnly {
                    columnVisibility.wrappedValue = .all
                }
            } else if columnVisibility.wrappedValue != .detailOnly {
                columnVisibility.wrappedValue = .detailOnly
            }
        }

        func applySidebarVisibilityIfNeeded(_ shouldShow: Bool) {
            guard lastAppliedShowSidebar != shouldShow else { return }
            lastAppliedShowSidebar = shouldShow
            guard let window = attachedWindow,
                  let splitView = Self.findSplitView(in: window.contentView?.superview),
                  let svc = splitView.delegate as? NSSplitViewController,
                  let sidebarItem = svc.splitViewItems.first else {
                return
            }
            if sidebarItem.isCollapsed != !shouldShow {
                sidebarItem.animator().isCollapsed = !shouldShow
            }
        }

        @objc func windowDidTransitionFullScreen(_ notification: Notification) {
            guard let window = attachedWindow else { return }
            configureWindowAppearance(window)
            bindSplitViewIfNeeded(in: window)
            if let splitView = Self.findSplitView(in: window.contentView?.superview),
               let svc = splitView.delegate as? NSSplitViewController,
               let sidebarItem = svc.splitViewItems.first {
                syncModelAndVisibility(isSidebarVisible: !sidebarItem.isCollapsed)
            }
        }

        @objc func windowDidChangeFrame(_ notification: Notification) {
            guard let window = attachedWindow,
                  !window.styleMask.contains(.fullScreen),
                  Self.isRestorableWindowFrame(window.frame, for: window) else {
                return
            }
            let frameString = NSStringFromRect(window.frame)
            userDefaults.set(frameString, forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey)
        }

        static func findSplitView(in root: NSView?) -> NSSplitView? {
            guard let root else { return nil }
            if let split = root as? NSSplitView {
                return split
            }
            for subview in root.subviews {
                if let found = findSplitView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }
}
