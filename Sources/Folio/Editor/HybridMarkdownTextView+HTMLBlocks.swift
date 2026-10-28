import AppKit

/// A selection inside a rendered HTML block, in text view terms.
public struct HTMLBlockSelection: Equatable {
    /// The selected range of the document source.
    public let sourceRange: NSRange
    public let isBackward: Bool
    /// Selection rects in text view coordinates.
    public let rects: [NSRect]
}

extension HybridMarkdownTextView: HTMLBlockWebViewDelegate {

    /// The current HTML block selection, mapped to the document source.
    public var htmlBlockSelection: HTMLBlockSelection? {
        guard let owner = htmlBlockSelectionOwner, owner.superview === self, let selection = owner.selection else { return nil }
        return HTMLBlockSelection(
            sourceRange: NSRange(location: owner.blockRange.location + selection.start, length: selection.end - selection.start),
            isBackward: selection.isBackward,
            rects: selection.rects.map { $0.offsetBy(dx: owner.frame.minX, dy: owner.frame.minY) }
        )
    }

    /// The range that comments and selection copies act on: the HTML block selection when
    /// there is one, else the text selection.
    public var commentSelectionRange: NSRange {
        htmlBlockSelection?.sourceRange ?? selectedRange()
    }

    /// True while a block's web view loads, or a measured height still waits for its restyle.
    var hasPendingHTMLBlockLayout: Bool {
        pendingHTMLBlockRestyle != nil || pendingHTMLBlockSourceToggle != nil || isHTMLBlockOverlaySyncScheduled || htmlBlockOverlays.contains { !$0.isReady }
    }

    var htmlBlockBaseDirectoryURL: URL? {
        workspaceViewModel?.currentFileURL?.deletingLastPathComponent() ?? workspaceViewModel?.workspaceFolderURL
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isApplyingHTMLBlockSelection, let owner = htmlBlockSelectionOwner {
            htmlBlockSelectionOwner = nil
            owner.clearSelection()
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleHTMLBlockOverlaySync()
    }

    // MARK: - Overlay Layout

    /// Rendered HTML blocks in document order.
    func renderedHTMLBlocks() -> [(source: String, range: NSRange, width: CGFloat, dimFactor: CGFloat)] {
        lineDecorations.compactMap { decoration in
            guard case let .htmlBlockRendered(source, range, width, dim) = decoration.kind else { return nil }
            return (source, range, width, dim)
        }
    }

    func scheduleHTMLBlockOverlaySync() {
        guard !isHTMLBlockOverlaySyncScheduled else { return }
        isHTMLBlockOverlaySyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHTMLBlockOverlaySyncScheduled = false
            self.syncHTMLBlockOverlays()
        }
    }

    /// Creates, moves, and removes web views so that each rendered HTML block within about a
    /// screen of the visible area has one, positioned over its hidden source lines.
    func syncHTMLBlockOverlays() {
        let blocks = renderedHTMLBlocks()
        guard window != nil, !isSourceCodeMode, !blocks.isEmpty else {
            removeHTMLBlockOverlays(htmlBlockOverlays)
            htmlBlockOverlays = []
            return
        }
        let margin = max(400.0, visibleRect.height)
        let visibleChars = visibleDecorationCharacterRange(for: visibleRect.insetBy(dx: 0, dy: -margin), margin: 0)
        let style = HTMLBlockPageStyle(theme: currentTheme, typography: typographySettings)
        let baseDirectory = htmlBlockBaseDirectoryURL

        var pool = htmlBlockOverlays
        var next: [HTMLBlockWebView] = []
        for block in blocks {
            if let visibleChars, !Self.decorationSpan(block.range, touches: visibleChars) { continue }
            let view: HTMLBlockWebView
            if let index = pool.firstIndex(where: { $0.source == block.source && $0.blockRange.location == block.range.location })
                ?? pool.firstIndex(where: { $0.source == block.source })
            {
                view = pool.remove(at: index)
                view.update(style: style, baseDirectoryURL: baseDirectory)
            } else {
                view = HTMLBlockWebView(
                    source: block.source, style: style, baseDirectoryURL: baseDirectory,
                    blockRange: block.range, layoutWidth: block.width
                )
                view.blockDelegate = self
                addSubview(view)
            }
            view.blockRange = block.range
            view.layoutWidth = block.width
            if let frame = htmlBlockFrame(for: view), view.frame != frame {
                view.frame = frame
            }
            view.setDimFactor(block.dimFactor)
            next.append(view)
        }
        removeHTMLBlockOverlays(pool)
        htmlBlockOverlays = next
        scheduleHTMLBlockHighlightPush()
    }

    private func removeHTMLBlockOverlays(_ views: [HTMLBlockWebView]) {
        guard !views.isEmpty else { return }
        for view in views {
            if htmlBlockSelectionOwner === view {
                htmlBlockSelectionOwner = nil
                workspaceViewModel?.updateSelectionStats(selectedRange: selectedRange())
            }
            if window?.firstResponder === view {
                window?.makeFirstResponder(self)
            }
            view.blockDelegate = nil
            view.removeFromSuperview()
        }
    }

    /// Frame of a block's web view: the column width, from the block's first hidden line, as
    /// tall as the measured page (or the reserved lines before it is measured).
    func htmlBlockFrame(for view: HTMLBlockWebView) -> NSRect? {
        guard let reserved = htmlBlockReservedRect(for: view.blockRange) else { return nil }
        let width = min(reserved.width, max(1.0, view.layoutWidth))
        let height = min(reserved.height, view.measuredHeight ?? reserved.height)
        return NSRect(x: reserved.minX, y: reserved.minY, width: width, height: max(1.0, height))
    }

    /// The text view rect of a block's hidden source lines, without the spacing after them.
    func htmlBlockReservedRect(for blockRange: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, blockRange.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
        guard glyphs.location != NSNotFound, glyphs.length > 0 else { return nil }
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let origin = textContainerOrigin
        let fullWidth = textContainer.containerSize.width > 0 ? textContainer.containerSize.width : bounds.width - origin.x * 2
        let columnWidth = proseColumnWidth > 0 ? min(proseColumnWidth, fullWidth) : fullWidth
        return NSRect(x: origin.x, y: origin.y + first.minY, width: columnWidth, height: max(1.0, last.maxY - first.minY))
    }

    // MARK: - Drawing Before Load and in Print

    /// Draws a block's last snapshot (or a quiet placeholder) where no ready web view covers it:
    /// before the page loads, and in print views, which have no web views.
    func drawHTMLBlockFallback(source: String, fullBlockRange: NSRange, dirtyRect: NSRect, dimFactor: CGFloat) {
        if htmlBlockOverlays.contains(where: { $0.isReady && $0.blockRange.location == fullBlockRange.location && $0.source == source }) {
            return
        }
        guard let rect = htmlBlockReservedRect(for: fullBlockRange), rect.intersects(dirtyRect) else { return }
        if let image = HTMLBlockLayoutCache.shared.snapshot(for: source), image.size.width > 0, image.size.height > 0 {
            let scale = min(1.0, rect.width / image.size.width)
            let drawRect = NSRect(x: rect.minX, y: rect.minY, width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: dimFactor, respectFlipped: true, hints: nil)
            return
        }
        currentTheme.codeBackgroundNSColor.withAlphaComponent(0.5 * dimFactor).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 6.0, yRadius: 6.0).fill()
    }

    // MARK: - Comment Highlights

    func scheduleHTMLBlockHighlightPush() {
        guard !htmlBlockOverlays.isEmpty, !isHTMLBlockHighlightPushScheduled else { return }
        isHTMLBlockHighlightPushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isHTMLBlockHighlightPushScheduled = false
            self.pushHTMLBlockHighlights()
        }
    }

    /// Sends each web view the comment and draft ranges that fall in its block.
    func pushHTMLBlockHighlights() {
        let comments = workspaceViewModel?.selectionComments ?? []
        let activeID = workspaceViewModel?.activeCommentID
        let draft = workspaceViewModel?.activeCommentDraftRange
        for view in htmlBlockOverlays {
            var items: [HTMLBlockWebView.Highlight] = []
            for comment in comments {
                guard let relative = Self.relativeRange(comment.range, in: view.blockRange) else { continue }
                let kind = comment.id == activeID ? "folio-comment-active" : "folio-comment"
                items.append(HTMLBlockWebView.Highlight(start: relative.location, end: NSMaxRange(relative), kind: kind))
            }
            if let draft, let relative = Self.relativeRange(draft, in: view.blockRange) {
                items.append(HTMLBlockWebView.Highlight(start: relative.location, end: NSMaxRange(relative), kind: "folio-draft"))
            }
            view.setHighlights(items)
        }
    }

    /// The part of `range` inside `block`, relative to the block start. Nil when they do not overlap.
    static func relativeRange(_ range: NSRange, in block: NSRange) -> NSRange? {
        let overlap = NSIntersectionRange(range, block)
        guard overlap.length > 0 else { return nil }
        return NSRange(location: overlap.location - block.location, length: overlap.length)
    }

    // MARK: - Selection Geometry and Programmatic Selection

    /// Tooltip anchor rects for a range in a rendered HTML block, where the source glyphs are
    /// hidden: the web selection rects, or the top of the block. Nil outside rendered blocks.
    func htmlBlockAnchorRects(for range: NSRange, direction: SelectionDirection) -> (bounding: NSRect, head: NSRect)? {
        if let selection = htmlBlockSelection, selection.sourceRange == range, let first = selection.rects.first, let last = selection.rects.last {
            let bounding = selection.rects.dropFirst().reduce(first) { $0.union($1) }
            let head =
                direction == .backward
                ? NSRect(x: first.minX, y: first.minY, width: 8.0, height: first.height)
                : NSRect(x: max(last.minX, last.maxX - 8.0), y: last.minY, width: 8.0, height: last.height)
            return (bounding, head)
        }
        guard let view = htmlBlockOverlays.first(where: { NSIntersectionRange($0.blockRange, range).length == range.length && range.length > 0 })
        else {
            return nil
        }
        let top = NSRect(x: view.frame.minX, y: view.frame.minY, width: view.frame.width, height: min(view.frame.height, 22.0))
        return (top, NSRect(x: top.minX, y: top.minY, width: 8.0, height: top.height))
    }

    /// Selects `range` inside a rendered HTML block's web view. Returns false when the range is
    /// not inside a rendered block, so the caller selects it in the text instead.
    @discardableResult
    public func selectHTMLBlockSource(_ range: NSRange) -> Bool {
        guard range.length > 0,
            let block = renderedHTMLBlocks().first(where: { NSIntersectionRange($0.range, range).length == range.length })
        else {
            return false
        }
        scrollRangeToVisible(range)
        syncHTMLBlockOverlays()
        guard let view = htmlBlockOverlays.first(where: { $0.blockRange.location == block.range.location }) else { return false }
        window?.makeFirstResponder(view)
        view.selectSource(start: range.location - block.range.location, end: NSMaxRange(range) - block.range.location)
        return true
    }

    // MARK: - HTMLBlockWebViewDelegate

    func htmlBlockWebView(_ view: HTMLBlockWebView, didMeasureHeight height: CGFloat) {
        let key = HTMLBlockLayoutCache.key(source: view.source, width: view.layoutWidth, style: view.style)
        if HTMLBlockLayoutCache.shared.setHeight(height, for: key) {
            scheduleHTMLBlockRestyle()
        } else if let frame = htmlBlockFrame(for: view), view.frame != frame {
            view.frame = frame
        }
    }

    /// Restyles after a block's measured height changed, so its hidden lines reserve the new
    /// height, then moves the web views to the new layout.
    private func scheduleHTMLBlockRestyle() {
        pendingHTMLBlockRestyle?.cancel()
        pendingHTMLBlockRestyle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            self.pendingHTMLBlockRestyle = nil
            self.editorCoordinator?.restyle(textView: self)
            self.syncHTMLBlockOverlays()
            self.needsDisplay = true
        }
    }

    func htmlBlockWebView(_ view: HTMLBlockWebView, didChangeSelection selection: HTMLBlockWebView.Selection?) {
        if selection != nil {
            pendingHTMLBlockSourceToggle?.cancel()
            pendingHTMLBlockSourceToggle = nil
            if let previous = htmlBlockSelectionOwner, previous !== view {
                previous.clearSelection()
            }
            let textSelection = selectedRange()
            if textSelection.length > 0 {
                isApplyingHTMLBlockSelection = true
                setSelectedRange(NSRange(location: textSelection.location, length: 0))
                isApplyingHTMLBlockSelection = false
            }
            htmlBlockSelectionOwner = view
            if let mapped = htmlBlockSelection {
                workspaceViewModel?.updateSelectionStats(
                    selectedRange: mapped.sourceRange,
                    direction: mapped.isBackward ? .backward : .forward
                )
            }
        } else if htmlBlockSelectionOwner === view {
            htmlBlockSelectionOwner = nil
            workspaceViewModel?.updateSelectionStats(selectedRange: selectedRange())
        }
    }

    /// A click on a comment highlight opens the comment. Any other single click shows the
    /// block source with the caret where the click was, after the double-click interval, so a
    /// double or triple click still selects text in the page.
    func htmlBlockWebView(_ view: HTMLBlockWebView, didClickSourceOffset offset: Int?, clickCount: Int) {
        pendingHTMLBlockSourceToggle?.cancel()
        pendingHTMLBlockSourceToggle = nil
        if let offset, let viewModel = workspaceViewModel,
            let comment = viewModel.comment(atCharacterIndex: view.blockRange.location + offset)
        {
            viewModel.handleCommentHighlightClick(comment)
            return
        }
        guard clickCount == 1 else { return }
        let sourceLength = (view.source as NSString).length
        let relative = max(0, min(offset ?? 0, sourceLength))
        pendingHTMLBlockSourceToggle = Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, let self, let view, view.superview === self, view.selection == nil else { return }
            self.pendingHTMLBlockSourceToggle = nil
            self.beginEditingHTMLBlockSource(view, at: view.blockRange.location + relative)
        }
    }

    /// Shows the block source by moving the caret into it, which makes the block active.
    func beginEditingHTMLBlockSource(_ view: HTMLBlockWebView, at location: Int) {
        let caret = NSRange(location: max(view.blockRange.location, min(location, NSMaxRange(view.blockRange))), length: 0)
        window?.makeFirstResponder(self)
        setSelectedRange(caret)
        scrollRangeToVisible(caret)
    }

    func htmlBlockWebViewDidBecomeReady(_ view: HTMLBlockWebView) {
        scheduleHTMLBlockHighlightPush()
        needsDisplay = true
    }

    func htmlBlockWebViewRequestsSourceEditing(_ view: HTMLBlockWebView) {
        beginEditingHTMLBlockSource(view, at: view.blockRange.location)
    }

    func htmlBlockWebViewRequestsComment(_ view: HTMLBlockWebView) {
        workspaceViewModel?.beginCommentOnCurrentSelection()
    }

    func htmlBlockWebViewRequestsRawCopy(_ view: HTMLBlockWebView) {
        workspaceViewModel?.copySelectionRaw()
    }

    func htmlBlockWebViewRequestsTextFocus(_ view: HTMLBlockWebView) {
        if htmlBlockSelectionOwner === view {
            htmlBlockSelectionOwner = nil
            view.clearSelection()
            workspaceViewModel?.updateSelectionStats(selectedRange: selectedRange())
        }
        window?.makeFirstResponder(self)
    }
}
