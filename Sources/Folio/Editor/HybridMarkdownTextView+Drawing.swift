import AppKit
import SwiftUI

extension HybridMarkdownTextView {

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = self.layoutManager,
            let textContainer = self.textContainer
        else {
            return
        }

        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        drawExternalUpdateAndCommentHighlights(
            in: rect,
            layoutManager: layoutManager,
            textContainer: textContainer,
            origin: origin,
            contentWidth: contentWidth
        )

        guard !isSourceCodeMode else {
            return
        }

        let visibleChars = visibleDecorationCharacterRange(for: rect)
        for (decIdx, dec) in lineDecorations.enumerated() {
            if case .codeFenceBody = dec.kind { continue }
            if case .codeFenceEnd = dec.kind { continue }
            if let visible = visibleChars, !Self.decorationSpan(decorationSpan(at: decIdx), touches: visible) { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }

            if case .codeFenceStart(let language) = dec.kind {
                var endDecIdx = decIdx
                var scanIdx = decIdx + 1
                while scanIdx < lineDecorations.count {
                    switch lineDecorations[scanIdx].kind {
                    case .codeFenceBody:
                        endDecIdx = scanIdx
                        scanIdx += 1
                    case .codeFenceEnd:
                        endDecIdx = scanIdx
                        scanIdx = lineDecorations.count
                    default:
                        scanIdx = lineDecorations.count
                    }
                }

                let firstFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                let endRange = lineDecorations[endDecIdx].lineRange
                let endGlyphs = layoutManager.glyphRange(forCharacterRange: endRange, actualCharacterRange: nil)
                let lastGlyphIdx =
                    endGlyphs.location != NSNotFound
                    ? max(endGlyphs.location, NSMaxRange(endGlyphs) - 1)
                    : max(glyphRange.location, NSMaxRange(glyphRange) - 1)
                let lastFrag = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyphIdx, effectiveRange: nil)

                let fenceTop = origin.y + firstFrag.minY - 2.0
                let fenceBottom = origin.y + lastFrag.maxY + 2.0
                // Cards nested in list items start at the item's text indent (code lines sit 14pt inside the card).
                let fencePara = textStorage?.attribute(.paragraphStyle, at: dec.lineRange.location, effectiveRange: nil) as? NSParagraphStyle
                let cardInset = min(max(0.0, (fencePara?.firstLineHeadIndent ?? 14.0) - 14.0), contentWidth * 0.5)
                let unifiedFenceRect = NSRect(
                    x: origin.x + cardInset,
                    y: fenceTop,
                    width: contentWidth - cardInset,
                    height: max(24.0, fenceBottom - fenceTop)
                )

                guard unifiedFenceRect.insetBy(dx: -20, dy: -50).intersects(rect) else { continue }

                currentTheme.codeBackgroundNSColor.setFill()
                let cardPath = NSBezierPath(roundedRect: unifiedFenceRect, xRadius: 7.0, yRadius: 7.0)
                cardPath.fill()

                let cardBorderColor =
                    currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.08)
                    : NSColor.black.withAlphaComponent(0.06)
                cardBorderColor.setStroke()
                let strokePath = NSBezierPath(roundedRect: unifiedFenceRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.0, yRadius: 7.0)
                strokePath.lineWidth = 1.0
                strokePath.stroke()

                if let badge = computeCodeFenceBadgeGeometry(
                    for: dec.lineRange,
                    language: language,
                    layoutManager: layoutManager,
                    origin: origin,
                    contentWidth: contentWidth
                ) {
                    badge.accent.withAlphaComponent(currentTheme.isDark ? 0.16 : 0.10).setFill()
                    let pillPath = NSBezierPath(roundedRect: badge.pillRect, xRadius: 4.5, yRadius: 4.5)
                    pillPath.fill()

                    badge.accent.withAlphaComponent(currentTheme.isDark ? 0.30 : 0.22).setStroke()
                    let pillBorder = NSBezierPath(roundedRect: badge.pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
                    pillBorder.lineWidth = 1.0
                    pillBorder.stroke()

                    badge.accent.setFill()
                    NSBezierPath(ovalIn: badge.dotRect).fill()

                    badge.badgeString.draw(at: badge.textPoint, withAttributes: badge.badgeAttributes)

                    // Draw crisp downward dropdown chevron (▾)
                    let chevron = NSBezierPath()
                    chevron.move(to: NSPoint(x: badge.chevronCenter.x - 2.8, y: badge.chevronCenter.y - 1.4))
                    chevron.line(to: NSPoint(x: badge.chevronCenter.x, y: badge.chevronCenter.y + 1.6))
                    chevron.line(to: NSPoint(x: badge.chevronCenter.x + 2.8, y: badge.chevronCenter.y - 1.4))
                    chevron.lineWidth = 1.35
                    chevron.lineCapStyle = .round
                    chevron.lineJoinStyle = .round
                    badge.accent.withAlphaComponent(0.85).setStroke()
                    chevron.stroke()
                }
                continue
            }

            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            lineRect.origin.x += origin.x
            lineRect.origin.y += origin.y
            lineRect.size.width = max(lineRect.size.width, contentWidth)

            if case let .tableRow(_, _, _, _, _, _, tableWidth, _) = dec.kind {
                lineRect.size.width = max(lineRect.size.width, tableWidth)
            }

            guard lineRect.insetBy(dx: -20, dy: -50).intersects(rect) else { continue }

            switch dec.kind {
            case .headingUnderline(let level):
                let borderColor =
                    currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(level == 1 ? 0.16 : 0.10)
                    : NSColor.black.withAlphaComponent(level == 1 ? 0.11 : 0.075)
                borderColor.setFill()

                let lastGlyphIndex = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: lastGlyphIndex, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: lastGlyphIndex)
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y
                let hFont = currentTheme.headingFont(level: level, scale: typographySettings.fontSizeScale)
                let descenderDepth = abs(hFont.descender)
                let offset = max(3.0, min(6.0, typographySettings.headingUnderlineOffset * (level == 1 ? 0.75 : 0.65)))
                let underlineY = baselineY + descenderDepth + offset

                let underlineRect = NSRect(x: origin.x, y: underlineY, width: contentWidth, height: level == 1 ? 1.5 : 1.0)
                underlineRect.fill()

            case .blockquote(let nestLevel):
                let bgAlpha: CGFloat = currentTheme.isDark ? 0.14 : 0.035
                currentTheme.linkNSColor.withAlphaComponent(bgAlpha).setFill()
                let bgRect = NSRect(x: origin.x, y: lineRect.minY, width: contentWidth, height: lineRect.height)
                bgRect.fill()

                for i in 0..<nestLevel {
                    let barX = origin.x + CGFloat(i) * 14.0
                    let barRect = NSRect(x: barX, y: lineRect.minY, width: 3.5, height: lineRect.height)
                    currentTheme.linkNSColor.withAlphaComponent(0.65).setFill()
                    NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()
                }

            case .codeFenceStart, .codeFenceBody, .codeFenceEnd:
                break

            case .mathBlockStart(let isActive), .mathBlockBody(let isActive), .mathBlockEnd(let isActive):
                if isActive {
                    let mathBg = currentTheme.codeBackgroundNSColor.withAlphaComponent(0.70)
                    mathBg.setFill()
                    let boxRect = NSRect(x: origin.x, y: lineRect.minY - 1, width: contentWidth, height: lineRect.height + 2)
                    boxRect.fill()
                }

            case .mathBlockRendered(let latex, let fullBlockRange, let dimFactor):
                let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
                guard blockGlyphs.location != NSNotFound else { continue }
                var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
                blockRect.origin.x = origin.x
                blockRect.origin.y += origin.y
                blockRect.size.width = contentWidth

                // Subtle card background for display math block
                let cardBg = currentTheme.codeBackgroundNSColor.withAlphaComponent(currentTheme.isDark ? 0.45 : 0.50)
                cardBg.setFill()
                let cardPath = NSBezierPath(roundedRect: blockRect.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8)
                cardPath.fill()

                let effectiveFontSize = currentTheme.baseFontSize * typographySettings.fontSizeScale
                let mathBox = LaTeXMathRenderer.layoutLatex(
                    latex,
                    baseFontSize: effectiveFontSize,
                    isDisplayStyle: true
                )
                let customMathColor: NSColor? =
                    (fullBlockRange.location != NSNotFound && fullBlockRange.location < (self.string as NSString).length)
                    ? (self.textStorage?.attribute(MarkdownLiveStyler.customColorAttributeKey, at: fullBlockRange.location, effectiveRange: nil) as? NSColor)
                    : nil
                let mathColor = (customMathColor ?? currentTheme.headingNSColor).withAlphaComponent(dimFactor)
                if mathBox.width == 0 && LaTeXMacroExpander.isStandaloneMacroDefinitionBlock(latex) {
                    let badgeText = "𝑓(x) LaTeX Macros" as NSString
                    let badgeAttrs: [NSAttributedString.Key: Any] = [
                        .font: currentTheme.codeFont(size: effectiveFontSize * 0.78),
                        .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(0.75 * dimFactor)
                    ]
                    let badgeSize = badgeText.size(withAttributes: badgeAttrs)
                    badgeText.draw(
                        at: NSPoint(x: origin.x + (contentWidth - badgeSize.width) * 0.5, y: blockRect.midY - badgeSize.height * 0.5),
                        withAttributes: badgeAttrs
                    )
                } else {
                    drawRenderedMathBlock(
                        mathBox: mathBox,
                        blockRect: blockRect,
                        origin: origin,
                        contentWidth: contentWidth,
                        effectiveFontSize: effectiveFontSize,
                        mathColor: mathColor,
                        dimFactor: dimFactor
                    )
                }

            case .inlineMathRendered(let latex, let mathRange, let fontSize, let dimFactor):
                guard mathRange.location != NSNotFound,
                    mathRange.location < (self.string as NSString).length
                else { continue }
                let firstGlyph = layoutManager.glyphIndexForCharacter(at: mathRange.location)
                guard firstGlyph != NSNotFound, firstGlyph < layoutManager.numberOfGlyphs else { continue }
                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: firstGlyph)
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: mathRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset

                let mathBox = LaTeXMathRenderer.layoutLatex(
                    latex,
                    baseFontSize: fontSize,
                    isDisplayStyle: false
                )
                let targetWidth = max(4.0, mathBox.width + 2.0)
                let drawX = origin.x + lineFrag.minX + glyphLoc.x + max(0.5, (targetWidth - mathBox.width) * 0.5)
                let customInlineColor =
                    self.textStorage?.attribute(MarkdownLiveStyler.customColorAttributeKey, at: mathRange.location, effectiveRange: nil) as? NSColor
                let mathColor = (customInlineColor ?? currentTheme.headingNSColor).withAlphaComponent(dimFactor)
                mathBox.drawBox(drawX, baselineY, mathColor)

            case let .inlineCode(codeRange, codeFontSize, dimFactor):
                let codeGlyphs = layoutManager.glyphRange(forCharacterRange: codeRange, actualCharacterRange: nil)
                guard codeGlyphs.location != NSNotFound, codeGlyphs.length > 0 else { continue }
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: codeRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let codeFont = currentTheme.codeFont(size: codeFontSize)
                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()

                // Draw one pill per line fragment so a code span that wraps does not cover both lines.
                var glyphIndex = codeGlyphs.location
                while glyphIndex < NSMaxRange(codeGlyphs) {
                    var fragmentGlyphs = NSRange()
                    let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentGlyphs)
                    let pieceGlyphs = NSIntersectionRange(fragmentGlyphs, codeGlyphs)
                    guard pieceGlyphs.length > 0 else { break }
                    var pieceRect = layoutManager.boundingRect(forGlyphRange: pieceGlyphs, in: textContainer)
                    pieceRect.origin.x += origin.x
                    let glyphLoc = layoutManager.location(forGlyphAt: pieceGlyphs.location)
                    let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset
                    let pillRect = NSRect(
                        x: pieceRect.minX - 3.0,
                        y: baselineY - codeFont.ascender - 2.0,
                        width: pieceRect.width + 6.0,
                        height: codeFont.ascender + abs(codeFont.descender) + 4.0
                    )
                    NSBezierPath(roundedRect: pillRect, xRadius: 4.0, yRadius: 4.0).fill()
                    glyphIndex = NSMaxRange(pieceGlyphs)
                }

            case let .kbdPill(kbdRange, kbdFontSize, dimFactor):
                let kbdGlyphs = layoutManager.glyphRange(forCharacterRange: kbdRange, actualCharacterRange: nil)
                guard kbdGlyphs.location != NSNotFound else { continue }
                var kbdRect = layoutManager.boundingRect(forGlyphRange: kbdGlyphs, in: textContainer)
                kbdRect.origin.x += origin.x
                kbdRect.origin.y += origin.y

                let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: kbdGlyphs.location, effectiveRange: nil)
                let glyphLoc = layoutManager.location(forGlyphAt: kbdGlyphs.location)
                let baselineOffset = (self.textStorage?.attribute(.baselineOffset, at: kbdRange.location, effectiveRange: nil) as? CGFloat) ?? 0.0
                let baselineY = origin.y + lineFrag.minY + glyphLoc.y - baselineOffset
                let kbdFont = currentTheme.codeFont(size: kbdFontSize)
                let pillTop = baselineY - kbdFont.ascender - 2.5
                let pillHeight = kbdFont.ascender + abs(kbdFont.descender) + 5.0
                let pillRect = NSRect(
                    x: kbdRect.minX - 4.0,
                    y: pillTop,
                    width: kbdRect.width + 8.0,
                    height: pillHeight
                )
                let shadowRect = pillRect.offsetBy(dx: 0, dy: 1.5)
                let shadowColor = NSColor.black.withAlphaComponent((currentTheme.isDark ? 0.45 : 0.08) * dimFactor)
                shadowColor.setFill()
                NSBezierPath(roundedRect: shadowRect, xRadius: 4.5, yRadius: 4.5).fill()

                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5).fill()

                let borderColor =
                    currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.22 * dimFactor)
                    : NSColor.black.withAlphaComponent(0.16 * dimFactor)
                borderColor.setStroke()
                let borderPath = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
                borderPath.lineWidth = 1.0
                borderPath.stroke()

            case .mermaidBlockRendered, .svgBlockRendered, .imageRendered, .listBullet, .horizontalRule, .tableRow, .latexPreambleCard, .latexTheoremCard,
                .latexAbstractCard, .latexInputCard, .latexEquationNumber, .latexSectionBadge, .latexInlinePill, .latexInlineText:
                drawMediaAndBlockDecoration(
                    dec,
                    glyphRange: glyphRange,
                    layoutManager: layoutManager,
                    textContainer: textContainer,
                    origin: origin,
                    contentWidth: contentWidth,
                    imageXOffsetByLineLocation: &imageXOffsetByLineLocation
                )
            }
        }
    }
}
