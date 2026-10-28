import AppKit

extension HybridMarkdownTextView {

    /// Character range under `rect`, widened by `margin` points, so `drawBackground` can skip
    /// decorations that are off screen. Each skipped decoration saves a glyph-range lookup and a
    /// bounding-rect layout query, and off-screen diagrams are not fetched or drawn at all.
    func visibleDecorationCharacterRange(for rect: NSRect, margin: CGFloat = 240.0) -> NSRange? {
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return nil }
        let origin = textContainerOrigin
        var containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -margin)
        containerRect.origin.x = 0
        containerRect.size.width = max(containerRect.width, textContainer.containerSize.width)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        guard glyphs.location != NSNotFound else { return nil }
        return layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// Character span that decoration `index` paints. A code fence card spans from its opening
    /// line to its closing fence, so it is drawn while any of its lines are visible.
    func decorationSpan(at index: Int) -> NSRange {
        let decoration = lineDecorations[index]
        switch decoration.kind {
        case .latexPreambleCard(_, _, let fullBlockRange, _),
            .latexTheoremCard(_, _, _, let fullBlockRange, _),
            .latexAbstractCard(_, let fullBlockRange, _),
            .latexEquationNumber(_, let fullBlockRange, _),
            .mathBlockRendered(_, let fullBlockRange, _),
            .mermaidBlockRendered(_, let fullBlockRange, _),
            .svgBlockRendered(_, let fullBlockRange, _),
            .htmlBlockRendered(_, let fullBlockRange, _, _):
            return fullBlockRange
        case .codeFenceStart:
            break
        default:
            return decoration.lineRange
        }
        var end = decoration.lineRange
        var scan = index + 1
        while scan < lineDecorations.count {
            switch lineDecorations[scan].kind {
            case .codeFenceBody:
                end = lineDecorations[scan].lineRange
                scan += 1
            case .codeFenceEnd:
                end = lineDecorations[scan].lineRange
                scan = lineDecorations.count
            default:
                scan = lineDecorations.count
            }
        }
        return NSRange(location: decoration.lineRange.location, length: NSMaxRange(end) - decoration.lineRange.location)
    }

    /// True when `span` overlaps `visible`. Empty spans count when their location is inside.
    static func decorationSpan(_ span: NSRange, touches visible: NSRange) -> Bool {
        if span.length == 0 {
            return span.location >= visible.location && span.location <= NSMaxRange(visible)
        }
        return span.location < NSMaxRange(visible) && visible.location < NSMaxRange(span)
    }
}
