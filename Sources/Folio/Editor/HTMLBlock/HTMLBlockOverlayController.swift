import AppKit

/// Owns the live `HTMLBlockWebView` overlays, selection state, and async restyle/toggle tasks
/// for a `HybridMarkdownTextView`.
@MainActor
final class HTMLBlockOverlayController {
    private(set) var overlays: [HTMLBlockWebView] = []
    weak var selectionOwner: HTMLBlockWebView?
    var isOverlaySyncScheduled = false
    var isHighlightPushScheduled = false
    var isApplyingSelection = false
    var pendingRestyle: Task<Void, Never>?
    var pendingSourceToggle: Task<Void, Never>?

    var hasPendingLayout: Bool {
        pendingRestyle != nil
            || pendingSourceToggle != nil
            || isOverlaySyncScheduled
            || overlays.contains { !$0.isReady || $0.hasPendingHeightReport }
    }

    func currentSelection(in textView: HybridMarkdownTextView) -> HTMLBlockSelection? {
        guard let owner = selectionOwner, owner.superview === textView, let selection = owner.selection else {
            return nil
        }
        return HTMLBlockSelection(
            sourceRange: NSRange(
                location: owner.blockRange.location + selection.start,
                length: selection.end - selection.start
            ),
            isBackward: selection.isBackward,
            rects: selection.rects.map { $0.offsetBy(dx: owner.frame.minX, dy: owner.frame.minY) }
        )
    }

    func clearSelectionOnTextViewSelectionChange() {
        guard !isApplyingSelection, let owner = selectionOwner else { return }
        selectionOwner = nil
        owner.clearSelection()
    }

    func tearDownAll(in textView: HybridMarkdownTextView?) {
        pendingRestyle?.cancel()
        pendingRestyle = nil
        pendingSourceToggle?.cancel()
        pendingSourceToggle = nil
        removeOverlays(overlays, in: textView)
        overlays = []
    }

    func scheduleOverlaySync(for textView: HybridMarkdownTextView) {
        guard !isOverlaySyncScheduled else { return }
        isOverlaySyncScheduled = true
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.isOverlaySyncScheduled = false
            self.syncOverlays(in: textView)
        }
    }

    func syncOverlays(in textView: HybridMarkdownTextView) {
        let blocks = textView.renderedHTMLBlocks()
        guard textView.window != nil, !textView.isSourceCodeMode, !blocks.isEmpty else {
            removeOverlays(overlays, in: textView)
            overlays = []
            return
        }
        let margin = max(400.0, textView.visibleRect.height)
        let visibleChars = textView.visibleDecorationCharacterRange(
            for: textView.visibleRect.insetBy(dx: 0, dy: -margin),
            margin: 0
        )
        let style = HTMLBlockPageStyle(theme: textView.currentTheme, typography: textView.typographySettings)
        let baseDirectory = textView.htmlBlockBaseDirectoryURL

        var pool = overlays
        var next: [HTMLBlockWebView] = []
        for block in blocks {
            if let visibleChars, !HybridMarkdownTextView.decorationSpan(block.range, touches: visibleChars) {
                continue
            }
            let view: HTMLBlockWebView
            if let index = pool.firstIndex(where: { $0.source == block.source && $0.blockRange.location == block.range.location })
                ?? pool.firstIndex(where: { $0.source == block.source })
            {
                view = pool.remove(at: index)
                view.update(style: style, baseDirectoryURL: baseDirectory)
            } else {
                view = HTMLBlockWebView(
                    source: block.source,
                    style: style,
                    baseDirectoryURL: baseDirectory,
                    blockRange: block.range,
                    layoutWidth: block.width
                )
                view.blockDelegate = textView
                textView.addSubview(view)
            }
            view.blockRange = block.range
            if let frame = textView.htmlBlockFrame(for: view, layoutWidth: block.width), view.frame != frame {
                view.frame = frame
            }
            view.layoutWidth = block.width
            view.setDimFactor(block.dimFactor)
            next.append(view)
        }
        removeOverlays(pool, in: textView)
        overlays = next
        scheduleHighlightPush(for: textView)
    }

    func removeOverlays(_ views: [HTMLBlockWebView], in textView: HybridMarkdownTextView?) {
        guard !views.isEmpty else { return }
        for view in views {
            if selectionOwner === view {
                selectionOwner = nil
                if let textView {
                    textView.workspaceViewModel?.updateSelectionStats(selectedRange: textView.selectedRange())
                }
            }
            if let textView, textView.window?.firstResponder === view {
                textView.window?.makeFirstResponder(textView)
            }
            view.tearDown()
        }
    }

    func scheduleHighlightPush(for textView: HybridMarkdownTextView) {
        guard !overlays.isEmpty, !isHighlightPushScheduled else { return }
        isHighlightPushScheduled = true
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.isHighlightPushScheduled = false
            self.pushHighlights(in: textView)
        }
    }

    func pushHighlights(in textView: HybridMarkdownTextView) {
        let comments = textView.workspaceViewModel?.selectionComments ?? []
        let activeID = textView.workspaceViewModel?.activeCommentID
        let draft = textView.workspaceViewModel?.activeCommentDraftRange
        for view in overlays {
            var items: [HTMLBlockWebView.Highlight] = []
            for comment in comments {
                guard let relative = HybridMarkdownTextView.relativeRange(comment.range, in: view.blockRange) else { continue }
                let kind = comment.id == activeID ? "folio-comment-active" : "folio-comment"
                items.append(HTMLBlockWebView.Highlight(start: relative.location, end: NSMaxRange(relative), kind: kind))
            }
            if let draft, let relative = HybridMarkdownTextView.relativeRange(draft, in: view.blockRange) {
                items.append(HTMLBlockWebView.Highlight(start: relative.location, end: NSMaxRange(relative), kind: "folio-draft"))
            }
            view.setHighlights(items)
        }
    }

    func scheduleRestyle(for textView: HybridMarkdownTextView) {
        pendingRestyle?.cancel()
        pendingRestyle = Task { @MainActor [weak self, weak textView] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self, let textView else { return }
            self.pendingRestyle = nil
            textView.editorCoordinator?.restyle(textView: textView)
            self.syncOverlays(in: textView)
            textView.needsDisplay = true
        }
    }
}
