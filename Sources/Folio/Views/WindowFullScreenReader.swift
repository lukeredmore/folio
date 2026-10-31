import AppKit
import SwiftUI

/// Reports whether the hosting window is in full screen, where the titlebar has no traffic lights.
struct WindowFullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.onChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
        view.onMoveToWindow = { [weak coordinator] window in coordinator?.observe(window) }
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {
        context.coordinator.onChange = { value in
            if isFullScreen != value { isFullScreen = value }
        }
        if let window = nsView.window { context.coordinator.observe(window) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onChange: ((Bool) -> Void)?
        private weak var window: NSWindow?
        private var lastReported: Bool?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(_ window: NSWindow) {
            if self.window !== window {
                NotificationCenter.default.removeObserver(self)
                self.window = window
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(fullScreenDidChange(_:)), name: name, object: window
                    )
                }
            }
            report(window.styleMask.contains(.fullScreen))
        }

        @objc private func fullScreenDidChange(_ notification: Notification) {
            guard let window else { return }
            report(window.styleMask.contains(.fullScreen))
        }

        private func report(_ value: Bool) {
            guard lastReported != value else { return }
            lastReported = value
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }
    }
}

extension View {
    /// Keeps `isFullScreen` equal to whether this view's window is in full screen.
    func readsWindowFullScreen(_ isFullScreen: Binding<Bool>) -> some View {
        background(
            WindowFullScreenReader(isFullScreen: isFullScreen)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}
