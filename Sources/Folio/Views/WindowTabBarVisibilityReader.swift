import AppKit
import SwiftUI

/// Reports whether the hosting window shows the native window tab bar.
///
/// The tab bar adds height below the toolbar that SwiftUI only exposes as a larger top safe area,
/// so views that bleed under the toolbar must know when it is present.
struct WindowTabBarVisibilityReader: NSViewRepresentable {
    @Binding var isTabBarVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.onChange = { visible in
            if isTabBarVisible != visible { isTabBarVisible = visible }
        }
        view.onMoveToWindow = { [weak coordinator] window in coordinator?.observe(window) }
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {
        context.coordinator.onChange = { visible in
            if isTabBarVisible != visible { isTabBarVisible = visible }
        }
        if let window = nsView.window { context.coordinator.observe(window) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: ((Bool) -> Void)?
        private weak var window: NSWindow?
        private weak var tabGroup: NSWindowTabGroup?
        private var observations: [NSKeyValueObservation] = []
        private var lastReported: Bool?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(_ window: NSWindow) {
            if self.window !== window {
                NotificationCenter.default.removeObserver(self)
                self.window = window
                let names: [Notification.Name] = [
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didBecomeMainNotification,
                    NSWindow.didEnterFullScreenNotification,
                    NSWindow.didExitFullScreenNotification
                ]
                for name in names {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowStateDidChange(_:)), name: name, object: window
                    )
                }
            }
            refresh()
        }

        @objc private func windowStateDidChange(_ notification: Notification) { refresh() }

        /// Re-binds KVO when the window joins a different tab group, then reports the current state.
        private func refresh() {
            guard let window else { return }
            if tabGroup !== window.tabGroup {
                tabGroup = window.tabGroup
                observations = observeTabGroup(window.tabGroup)
            }
            report(window.tabGroup?.isTabBarVisible ?? false)
        }

        private func observeTabGroup(_ group: NSWindowTabGroup?) -> [NSKeyValueObservation] {
            guard let group else { return [] }
            let handler: @Sendable (NSWindowTabGroup, Any) -> Void = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            return [
                group.observe(\.isTabBarVisible, options: [.new]) { group, change in handler(group, change) },
                group.observe(\.windows, options: [.new]) { group, change in handler(group, change) }
            ]
        }

        private func report(_ visible: Bool) {
            guard lastReported != visible else { return }
            lastReported = visible
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}

extension View {
    /// Keeps `isVisible` equal to whether this view's window shows the native tab bar.
    func readsWindowTabBarVisibility(_ isVisible: Binding<Bool>) -> some View {
        background(
            WindowTabBarVisibilityReader(isTabBarVisible: isVisible)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
