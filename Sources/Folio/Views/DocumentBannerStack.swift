import AppKit
import SwiftUI

/// The document banners pinned to the top of the editor column.
///
/// Place it where the top safe area applies so it starts below the titlebar, toolbar, and any
/// native tab bar, even when the editor canvas behind it bleeds under the toolbar.
struct DocumentBannerStack: View {
    static let layoutRegionIdentifier = "DocumentBannerStack"
    @ObservedObject var viewModel: EditorWorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            RemoteConnectionBannerView(viewModel: viewModel)
            if viewModel.showFindReplaceBar {
                FindReplaceBannerView(viewModel: viewModel)
            }
        }
        .background(LayoutRegionMarker(identifier: Self.layoutRegionIdentifier))
    }
}

/// A pass-through NSView that exposes the window frame of a SwiftUI region to AppKit code and tests.
struct LayoutRegionMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {}
}
