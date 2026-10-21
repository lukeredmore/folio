import AppKit

/// A table that is wider than the canvas. It is pinned to the canvas margin and scrolls
/// horizontally on its own, so the canvas never scrolls sideways.
struct OverflowingTable: Equatable {
    let range: NSRange
    let width: CGFloat
    let visibleWidth: CGFloat
    var maxScroll: CGFloat { max(0, width - visibleWidth) }
}

extension HybridMarkdownTextView {

    /// Gap between the canvas edge and a table that is wider than the canvas.
    static let wideTableCanvasMargin: CGFloat = 24.0

    /// Tables as `(characters, width)`, from consecutive `.tableRow` decorations.
    static func tableSpans(in decorations: [LineDecoration]) -> [(range: NSRange, width: CGFloat)] {
        var spans: [(range: NSRange, width: CGFloat)] = []
        for decoration in decorations {
            guard case let .tableRow(_, _, _, _, _, _, tableWidth, _) = decoration.kind else { continue }
            if let last = spans.last, NSMaxRange(last.range) == decoration.lineRange.location {
                spans[spans.count - 1] = (NSUnionRange(last.range, decoration.lineRange), max(last.width, tableWidth))
            } else {
                spans.append((decoration.lineRange, tableWidth))
            }
        }
        return spans
    }

    /// Lays out tables wider than the column: centered on the column at full width when they fit
    /// the canvas, otherwise pinned to the canvas margin and scrolled by `tableScrollOffsets`.
    func refreshWideTableLayout() {
        guard let container = textContainer as? WideBlockTextContainer, let layoutManager = layoutManager else { return }
        let column = container.containerSize.width
        let margin = Self.wideTableCanvasMargin
        let available = max(column, bounds.width - margin * 2)
        let leftOfColumn = max(0, textContainerOrigin.x - margin)

        var regions: [WideBlockTextContainer.Region] = []
        var overflowing: [OverflowingTable] = []
        for table in Self.tableSpans(in: lineDecorations) where table.width > column + 0.5 {
            let width = ceil(table.width)
            if width <= available {
                regions.append(.init(range: table.range, x: -floor((width - column) / 2), width: width))
            } else {
                let info = OverflowingTable(range: table.range, width: width, visibleWidth: available)
                let offset = min(max(0, tableScrollOffsets[table.range.location] ?? 0), info.maxScroll)
                tableScrollOffsets[table.range.location] = offset
                regions.append(.init(range: table.range, x: -leftOfColumn - offset, width: width))
                overflowing.append(info)
            }
        }
        overflowingTables = overflowing
        let changed = container.setRegions(regions)
        for range in changed where NSMaxRange(range) <= (string as NSString).length {
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
        if !changed.isEmpty { needsDisplay = true }
    }

    /// View-space rect covered by the rows in `range`.
    func tableRect(for range: NSRange) -> NSRect? {
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func overflowingTable(at point: NSPoint) -> OverflowingTable? {
        overflowingTables.first { table in
            guard let rect = tableRect(for: table.range) else { return false }
            return point.y >= rect.minY && point.y <= rect.maxY + 6
        }
    }

    /// Horizontal scrolling over a table that is wider than the canvas scrolls only that table.
    public override func scrollWheel(with event: NSEvent) {
        let horizontal: CGFloat
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            horizontal = event.scrollingDeltaX
        } else if event.modifierFlags.contains(.shift) {
            horizontal = event.scrollingDeltaY
        } else {
            horizontal = 0
        }
        if horizontal != 0, scrollOverflowingTable(at: convert(event.locationInWindow, from: nil), by: horizontal) {
            return
        }
        super.scrollWheel(with: event)
    }

    /// Scrolls the overflowing table under `point` by `delta` points (positive moves content
    /// right). Returns false when no overflowing table is under `point`.
    @discardableResult
    func scrollOverflowingTable(at point: NSPoint, by delta: CGFloat) -> Bool {
        guard let table = overflowingTable(at: point) else { return false }
        let current = tableScrollOffsets[table.range.location] ?? 0
        let next = min(max(0, current - delta), table.maxScroll)
        if next != current {
            tableScrollOffsets[table.range.location] = next
            refreshWideTableLayout()
        }
        return true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // NSTextView leaves its clip at the column; wide tables and their indicators extend past it.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirtyRect).setClip()
        drawWideTableGlyphs(in: dirtyRect)
        drawTableScrollIndicators(in: dirtyRect)
    }

    /// Draws wide table rows, which NSTextView's text pass skips (see WideBlockLayoutManager),
    /// without clipping them to the column.
    private func drawWideTableGlyphs(in dirtyRect: NSRect) {
        guard let layoutManager = layoutManager as? WideBlockLayoutManager else { return }
        layoutManager.drawWideRegionGlyphs(intersecting: dirtyRect, at: textContainerOrigin)
    }

    /// Thin scroll indicator under each table that is wider than the canvas.
    private func drawTableScrollIndicators(in dirtyRect: NSRect) {
        let margin = Self.wideTableCanvasMargin
        for table in overflowingTables {
            guard let rect = tableRect(for: table.range) else { continue }
            let track = NSRect(x: margin, y: rect.maxY + 3, width: table.visibleWidth, height: 4)
            guard track.intersects(dirtyRect) else { continue }
            let thumbWidth = max(24, track.width * table.visibleWidth / table.width)
            let progress = table.maxScroll > 0 ? (tableScrollOffsets[table.range.location] ?? 0) / table.maxScroll : 0
            let thumb = NSRect(x: track.minX + (track.width - thumbWidth) * progress, y: track.minY, width: thumbWidth, height: track.height)
            currentTheme.secondaryTextNSColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            currentTheme.secondaryTextNSColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
        }
    }
}
