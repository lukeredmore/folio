import AppKit
import SwiftUI

public enum SelectionTooltipActionKind: String, CaseIterable, Identifiable, Sendable {
    case comment
    case copyFormatted
    case copyRaw

    public var id: String { rawValue }
}

public struct SelectionActionTooltipView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    let anchor: SelectionTooltipAnchor

    @FocusState private var isCommentFieldFocused: Bool
    @State private var hoveredAction: SelectionTooltipActionKind?
    @State private var copiedAction: SelectionTooltipActionKind?

    public init(viewModel: EditorWorkspaceViewModel, anchor: SelectionTooltipAnchor) {
        self.viewModel = viewModel
        self.anchor = anchor
    }

    private var isComposingComment: Bool { viewModel.activeCommentDraftRange != nil }
    private var existingComment: SelectionComment? { viewModel.existingComment(overlapping: anchor.range) }

    public var body: some View {
        let layout = Self.tooltipPosition(for: anchor, isExpanded: isComposingComment)
        ZStack(alignment: .topLeading) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            Group {
                if isComposingComment {
                    commentComposerCard
                } else {
                    verticalIconRail
                }
            }
            .position(x: layout.centerX, y: layout.centerY)
            .animation(.easeOut(duration: 0.14), value: isComposingComment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear {
            if isComposingComment {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { isCommentFieldFocused = true }
            }
        }
        .onChange(of: isComposingComment) { _, newValue in
            if newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { isCommentFieldFocused = true }
            }
        }
    }

    private var verticalIconRail: some View {
        VStack(spacing: 4) {
            verticalIconButton(
                kind: .comment,
                icon: existingComment != nil ? "text.bubble.fill" : "text.bubble",
                label: existingComment != nil ? "Edit Comment" : "Add Comment"
            ) {
                viewModel.beginCommentOnCurrentSelection(for: anchor.range)
            }

            railDivider

            verticalIconButton(
                kind: .copyFormatted,
                icon: copiedAction == .copyFormatted ? "checkmark" : "doc.richtext",
                label: "Copy Formatted"
            ) {
                if viewModel.copySelectionFormatted(for: anchor.range) != nil {
                    triggerCopiedFeedback(kind: .copyFormatted)
                }
            }

            railDivider

            verticalIconButton(
                kind: .copyRaw,
                icon: copiedAction == .copyRaw ? "checkmark" : "doc.plaintext",
                label: "Copy Raw Markdown"
            ) {
                if viewModel.copySelectionRaw(for: anchor.range) != nil {
                    triggerCopiedFeedback(kind: .copyRaw)
                }
            }
        }
        .padding(5)
        .background(tooltipBackground(cornerRadius: 10))
    }

    private func verticalIconButton(
        kind: SelectionTooltipActionKind,
        icon: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = (hoveredAction == kind)
        return Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        isHovered
                            ? viewModel.theme.textColor.opacity(viewModel.theme.isDark ? 0.12 : 0.07)
                            : Color.clear
                    )
                Image(systemName: icon)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(
                        isHovered
                            ? viewModel.theme.textColor
                            : viewModel.theme.textColor.opacity(0.78)
                    )
            }
            .frame(width: 34, height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.borderless)
        .onHover { hovering in
            if hovering {
                hoveredAction = kind
            } else if hoveredAction == kind {
                hoveredAction = nil
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var railDivider: some View {
        Rectangle()
            .fill(viewModel.theme.borderColor.opacity(0.75))
            .frame(width: 22, height: 1)
    }

    private var commentComposerCard: some View {
        let isDraftEmpty = viewModel.activeCommentDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            TextField("Add a comment…", text: $viewModel.activeCommentDraftText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(viewModel.theme.textColor)
                .focused($isCommentFieldFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(viewModel.theme.editorBackgroundColor)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(viewModel.theme.borderColor, lineWidth: 1))
                )
                .onSubmit { viewModel.addOrUpdateSelectionComment(for: anchor.range) }

            if let existing = existingComment {
                Button {
                    viewModel.removeSelectionComment(id: existing.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(viewModel.theme.secondaryTextColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Delete comment")
            }

            Button {
                viewModel.addOrUpdateSelectionComment(for: anchor.range)
            } label: {
                Text(existingComment != nil ? "Save" : "Add")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(viewModel.theme.linkColor.opacity(isDraftEmpty ? 0.45 : 1.0))
                    )
            }
            .buttonStyle(.borderless)
            .disabled(isDraftEmpty)
            .help("Save comment (Return)")

            Button {
                viewModel.cancelCommentDraft()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(viewModel.theme.secondaryTextColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Cancel (Esc)")
        }
        .padding(7)
        .frame(width: 320)
        .background(tooltipBackground(cornerRadius: 9))
    }

    private func tooltipBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(viewModel.theme.sidebarBackgroundColor)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(viewModel.theme.borderColor, lineWidth: 1))
            .shadow(color: Color.black.opacity(viewModel.theme.isDark ? 0.45 : 0.16), radius: 8, x: 0, y: 3)
    }

    private func triggerCopiedFeedback(kind: SelectionTooltipActionKind) {
        copiedAction = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if copiedAction == kind { copiedAction = nil }
        }
    }

    /// Computes intelligent selection-direction-aligned coordinates for the vertical 3-icon rail or expanded composer.
    /// `topMargin` keeps the floating tooltip below the 52pt transparent unified window toolbar (`NSTitlebarContainerView`)
    /// so AppKit window titlebar hit-testing never swallows mouse clicks on top-of-document selections.
    public static func tooltipPosition(
        for anchor: SelectionTooltipAnchor,
        isExpanded: Bool
    ) -> (centerX: CGFloat, centerY: CGFloat) {
        let cardWidth: CGFloat = isExpanded ? 320.0 : 46.0
        let cardHeight: CGFloat = isExpanded ? 44.0 : 124.0
        let halfW = cardWidth * 0.5
        let halfH = cardHeight * 0.5
        let margin: CGFloat = 12.0
        let topMargin: CGFloat = 58.0
        let minY = halfH + topMargin
        let viewportW = max(cardWidth + margin * 2, anchor.viewportSize.width)
        let viewportH = max(cardHeight + topMargin + margin, anchor.viewportSize.height)
        let maxY = max(minY, viewportH - halfH - margin)

        let selRect = anchor.selectionRectInViewport
        let headRect = anchor.headRectInViewport
        let gap: CGFloat = 10.0

        if !isExpanded {
            let preferredX: CGFloat
            let preferredY: CGFloat
            switch anchor.direction {
            case .backward:
                let leftCandidateX = headRect.minX - gap - halfW
                let rightFallbackX = headRect.maxX + gap + halfW
                preferredX = leftCandidateX >= (halfW + margin) ? leftCandidateX : rightFallbackX
                preferredY = headRect.minY + halfH - 4.0
            case .forward:
                let rightCandidateX = headRect.maxX + gap + halfW
                let leftFallbackX = headRect.minX - gap - halfW
                preferredX = rightCandidateX <= (viewportW - halfW - margin) ? rightCandidateX : leftFallbackX
                preferredY = headRect.midY + halfH - 22.0
            }
            let clampedX = min(max(halfW + margin, preferredX), viewportW - halfW - margin)
            let clampedY = min(max(minY, preferredY), maxY)
            return (clampedX, clampedY)
        }

        let targetX = anchor.direction == .backward ? headRect.minX + halfW : headRect.maxX - halfW
        let clampedX = min(max(halfW + margin, targetX), viewportW - halfW - margin)
        let aboveCenterY = selRect.minY - halfH - 8.0
        let belowCenterY = selRect.maxY + halfH + 8.0
        let rawY =
            anchor.direction == .backward
            ? (aboveCenterY >= minY ? aboveCenterY : belowCenterY)
            : (belowCenterY <= maxY ? belowCenterY : aboveCenterY)
        let clampedY = min(max(minY, rawY), maxY)
        return (clampedX, clampedY)
    }
}

public final class SelectionTooltipHostingView: NSHostingView<SelectionActionTooltipView> {
    public override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let localPt = convert(point, from: superview)
        let topLeftY = isFlipped ? localPt.y : (bounds.height - localPt.y)
        let topLeftPt = NSPoint(x: localPt.x, y: topLeftY)
        let isExpanded = (rootView.viewModel.activeCommentDraftRange != nil)
        let pos = SelectionActionTooltipView.tooltipPosition(for: rootView.anchor, isExpanded: isExpanded)
        let width: CGFloat = isExpanded ? 320.0 : 46.0
        let height: CGFloat = isExpanded ? 44.0 : 124.0
        let cardRect = NSRect(x: pos.centerX - width * 0.5, y: pos.centerY - height * 0.5, width: width, height: height)
        guard cardRect.insetBy(dx: -6, dy: -6).contains(topLeftPt) else {
            return nil
        }
        return super.hitTest(point) ?? self
    }
}

public struct SelectionTooltipOverlayRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    let anchor: SelectionTooltipAnchor

    public init(viewModel: EditorWorkspaceViewModel, anchor: SelectionTooltipAnchor) {
        self.viewModel = viewModel
        self.anchor = anchor
    }

    public func makeNSView(context: Context) -> SelectionTooltipHostingView {
        SelectionTooltipHostingView(rootView: SelectionActionTooltipView(viewModel: viewModel, anchor: anchor))
    }

    public func updateNSView(_ nsView: SelectionTooltipHostingView, context: Context) {
        nsView.rootView = SelectionActionTooltipView(viewModel: viewModel, anchor: anchor)
    }
}
