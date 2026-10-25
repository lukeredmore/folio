import AppKit

extension HybridMarkdownTextView {

    /// View-space rects of rendered cards that must not be split across printed pages: Mermaid
    /// and SVG diagrams, display math, and images.
    func unbreakableBlockRects() -> [NSRect] {
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return [] }
        let length = (string as NSString).length
        return lineDecorations.compactMap { decoration -> NSRect? in
            let range: NSRange
            switch decoration.kind {
            case let .mermaidBlockRendered(_, fullBlockRange, _),
                 let .svgBlockRendered(_, fullBlockRange, _),
                 let .mathBlockRendered(_, fullBlockRange, _),
                 let .latexTheoremCard(_, _, _, fullBlockRange, _),
                 let .latexAbstractCard(_, fullBlockRange, _):
                range = fullBlockRange
            case .imageRendered, .latexInputCard:
                range = decoration.lineRange
            default:
                return nil
            }
            guard range.length > 0, NSMaxRange(range) <= length else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
    }

    /// Moves a page break that would cut through a rendered card to just above the card, when the
    /// card fits on the next page.
    public override func adjustPageHeightNew(
        _ newBottom: UnsafeMutablePointer<CGFloat>,
        top oldTop: CGFloat,
        bottom oldBottom: CGFloat,
        limit bottomLimit: CGFloat
    ) {
        super.adjustPageHeightNew(newBottom, top: oldTop, bottom: oldBottom, limit: bottomLimit)
        newBottom.pointee = Self.pageBottom(
            newBottom.pointee,
            pageTop: oldTop,
            pageHeight: oldBottom - oldTop,
            limit: bottomLimit,
            avoiding: unbreakableBlockRects()
        )
    }

    /// Page bottom that does not cut through any of `cards`: a break inside a card moves to the
    /// card's top, unless the card is taller than a page or the move would pass `limit`.
    static func pageBottom(
        _ proposed: CGFloat,
        pageTop: CGFloat,
        pageHeight: CGFloat,
        limit: CGFloat,
        avoiding cards: [NSRect]
    ) -> CGFloat {
        var bottom = proposed
        for card in cards where card.minY < bottom && card.maxY > bottom {
            guard card.minY > pageTop + 1, card.minY >= limit, card.height <= pageHeight else { continue }
            bottom = min(bottom, card.minY)
        }
        return bottom
    }
}
