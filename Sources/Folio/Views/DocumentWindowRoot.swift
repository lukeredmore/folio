import AppKit
import SwiftUI

/// Root view of one document window or tab. It owns the window's view model.
struct DocumentWindowRoot: View {
    @StateObject private var viewModel: EditorWorkspaceViewModel
    @Environment(\.openWindow) private var openWindow
    private let registry: DocumentWindowRegistry
    private let onAppear: (EditorWorkspaceViewModel) -> Void

    init(
        value: DocumentWindowValue,
        registry: DocumentWindowRegistry,
        onAppear: @escaping (EditorWorkspaceViewModel) -> Void
    ) {
        self.registry = registry
        self.onAppear = onAppear
        _viewModel = StateObject(wrappedValue: registry.makeViewModel(for: value))
    }

    var body: some View {
        MainWindowView(viewModel: viewModel)
            .frame(minWidth: 720, minHeight: 480)
            .navigationTitle(viewModel.documentTitle)
            .focusedSceneObject(viewModel)
            .background(
                DocumentHostWindowAccessor { [registry, viewModel] window in
                    registry.attach(window, to: viewModel)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            )
            .onAppear {
                registry.openWindowAction = openWindow
                onAppear(viewModel)
            }
    }
}

/// Reports the `NSWindow` that hosts this view each time the view moves into a window.
struct DocumentHostWindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        view.onMoveToWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {
        nsView.onMoveToWindow = onWindow
    }
}
