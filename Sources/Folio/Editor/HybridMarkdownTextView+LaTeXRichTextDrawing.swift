import AppKit
import Foundation

extension HybridMarkdownTextView {

    /// Draws an expanded prose macro over the atomic span that hides its source. Runs on a line
    /// share the baseline of the span's first glyph; each further line moves down one line step.
    func drawLaTeXInlineRichText(
        lines: [[LaTeXInlineRichRun]],
        spanRange: NSRange,
        dimFactor: CGFloat,
        layoutManager: NSLayoutManager,
        origin: NSPoint
    ) {
        guard spanRange.location != NSNotFound, spanRange.location < (self.string as NSString).length else { return }
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: spanRange.location)
        guard firstGlyph != NSNotFound, firstGlyph < layoutManager.numberOfGlyphs else { return }
        let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let glyphLoc = layoutManager.location(forGlyphAt: firstGlyph)
        let baselineY = origin.y + lineFrag.minY + glyphLoc.y
        let startX = origin.x + lineFrag.minX + glyphLoc.x
        let customColor =
            self.textStorage?.attribute(MarkdownLiveStyler.customColorAttributeKey, at: spanRange.location, effectiveRange: nil) as? NSColor
        let textColor = (customColor ?? currentTheme.textNSColor).withAlphaComponent(dimFactor)
        let mathColor = (customColor ?? currentTheme.headingNSColor).withAlphaComponent(dimFactor)
        let lineStep = LaTeXLiveStyler.richTextLineStep(lines)

        for (lineIndex, runs) in lines.enumerated() {
            var x = startX
            let lineBaseline = baselineY + CGFloat(lineIndex) * lineStep
            for run in runs {
                switch run {
                case let .text(text, font, underline, offset):
                    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
                    if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    let ns = text as NSString
                    ns.draw(at: NSPoint(x: x, y: lineBaseline - offset - font.ascender), withAttributes: attrs)
                    x += ns.size(withAttributes: [.font: font]).width
                case let .math(latex, fontSize, offset):
                    let box = LaTeXMathRenderer.layoutLatex(latex, baseFontSize: fontSize, isDisplayStyle: false)
                    box.drawBox(x, lineBaseline - offset, mathColor)
                    x += box.width
                }
            }
        }
    }
}
