import AppKit
import SwiftUI

/// Bounds of the autosave indicator in the bottom status bar, which anchors the external-update tooltip.
struct AutosaveIndicatorAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Tooltip card that rises from the autosave indicator when the open file changes on disk.
struct ExternalUpdateTooltipView: View {
    static let layoutRegionIdentifier = "ExternalUpdateTooltip"
    static let arrowHeight: CGFloat = 6
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    let notice: ExternalUpdateNotice
    let arrowCenterX: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: notice.wasThreeWayMerged ? "arrow.triangle.branch" : "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(notice.headlineText) in \(notice.fileURL.lastPathComponent) (\(notice.summaryText))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(viewModel.theme.textColor)
                    Text("Changed lines are highlighted in green in the editor.")
                        .font(.system(size: 10.5))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                Spacer(minLength: 4)
                Button {
                    viewModel.dismissExternalUpdateNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("View Diff") { viewModel.showExternalUpdateDiffModal = true }
                Button("Undo Update") {
                    viewModel.undo()
                    viewModel.dismissExternalUpdateNotice()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(cardBackground)
        .padding(.bottom, Self.arrowHeight)
        .background(LayoutRegionMarker(identifier: Self.layoutRegionIdentifier))
    }

    private var cardBackground: some View {
        let shape = TooltipCardShape(arrowCenterX: arrowCenterX, arrowHeight: Self.arrowHeight)
        return ZStack {
            shape.fill(viewModel.theme.editorBackgroundColor)
            shape.fill(Color.green.opacity(viewModel.theme.isDark ? 0.16 : 0.10))
            shape.stroke(Color.green.opacity(0.45), lineWidth: 1)
        }
        .padding(.bottom, -Self.arrowHeight)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

/// Rounded card with a downward arrow at `arrowCenterX` that points at the anchor below it.
struct TooltipCardShape: Shape {
    let arrowCenterX: CGFloat
    let arrowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let card = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - arrowHeight)
        var path = Path(roundedRect: card, cornerRadius: 10)
        let tipX = min(max(arrowCenterX, card.minX + 16), card.maxX - 16)
        path.move(to: CGPoint(x: tipX - arrowHeight, y: card.maxY))
        path.addLine(to: CGPoint(x: tipX, y: rect.maxY))
        path.addLine(to: CGPoint(x: tipX + arrowHeight, y: card.maxY))
        path.closeSubpath()
        return path
    }
}

/// Hosts the tooltip in its own NSHostingView so its buttons receive clicks above the NSTextView.
final class ExternalUpdateTooltipHostingView: NSHostingView<ExternalUpdateTooltipView> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ExternalUpdateTooltipHost: NSViewRepresentable {
    let tooltip: ExternalUpdateTooltipView

    func makeNSView(context: Context) -> ExternalUpdateTooltipHostingView {
        ExternalUpdateTooltipHostingView(rootView: tooltip)
    }

    func updateNSView(_ nsView: ExternalUpdateTooltipHostingView, context: Context) {
        nsView.rootView = tooltip
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ExternalUpdateTooltipHostingView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// Places the tooltip above the autosave indicator, inside the column's horizontal bounds.
struct ExternalUpdateTooltipOverlay: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    let anchor: Anchor<CGRect>?
    private let cardWidth: CGFloat = 340
    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            if let anchor, let notice = viewModel.externalUpdateNotice, viewModel.activeConflict == nil {
                let indicator = proxy[anchor]
                let leading = min(max(8, indicator.midX - 24), max(8, proxy.size.width - cardWidth - 8))
                let tooltip = ExternalUpdateTooltipView(
                    viewModel: viewModel,
                    notice: notice,
                    arrowCenterX: indicator.midX - leading
                )
                ExternalUpdateTooltipHost(tooltip: tooltip)
                    .fixedSize()
                    .padding(.leading, leading)
                    .padding(.bottom, max(0, proxy.size.height - indicator.minY + gap))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
            }
        }
    }
}
