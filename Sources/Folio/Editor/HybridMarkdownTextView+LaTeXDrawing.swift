import AppKit
import Foundation

extension HybridMarkdownTextView {

    func drawLaTeXDecoration(
        _ dec: LineDecoration,
        glyphRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: NSPoint,
        contentWidth: CGFloat
    ) {
        let effectiveFontSize = currentTheme.baseFontSize * typographySettings.fontSizeScale

        switch dec.kind {
        case let .latexPreambleCard(title, subtitle, fullBlockRange, dimFactor):
            let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
            guard blockGlyphs.location != NSNotFound else { return }
            var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockRect.origin.x = origin.x
            blockRect.origin.y += origin.y
            blockRect.size.width = contentWidth

            let cardRect = blockRect.insetBy(dx: 0, dy: 2.0)
            currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 7.0, yRadius: 7.0).fill()

            let borderCol = currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.12 * dimFactor)
                : NSColor.black.withAlphaComponent(0.09 * dimFactor)
            borderCol.setStroke()
            NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.0, yRadius: 7.0).stroke()

            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10.0, weight: .semibold),
                .foregroundColor: currentTheme.linkNSColor.withAlphaComponent(dimFactor)
            ]
            let badgeStr = "TeX PREAMBLE" as NSString
            let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
            let pillRect = NSRect(
                x: cardRect.minX + 10.0,
                y: cardRect.midY - badgeSize.height * 0.5 - 2.5,
                width: badgeSize.width + 10.0,
                height: badgeSize.height + 5.0
            )
            currentTheme.linkNSColor.withAlphaComponent(0.14 * dimFactor).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 4.0, yRadius: 4.0).fill()
            badgeStr.draw(at: NSPoint(x: pillRect.minX + 5.0, y: pillRect.minY + 2.5), withAttributes: badgeAttrs)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: currentTheme.bodyFont(size: 12.0, semibold: true),
                .foregroundColor: currentTheme.textNSColor.withAlphaComponent(dimFactor)
            ]
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: currentTheme.codeFont(size: 10.5),
                .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(0.85 * dimFactor)
            ]
            let titleX = pillRect.maxX + 10.0
            let titleStr = title as NSString
            let titleSize = titleStr.size(withAttributes: titleAttrs)
            titleStr.draw(at: NSPoint(x: titleX, y: cardRect.midY - titleSize.height * 0.5), withAttributes: titleAttrs)

            if !subtitle.isEmpty {
                let subX = titleX + titleSize.width + 10.0
                let maxSubW = max(0.0, cardRect.maxX - subX - 90.0)
                if maxSubW > 60.0 {
                    let subStr = subtitle as NSString
                    let subSize = subStr.size(withAttributes: subAttrs)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: NSRect(x: subX, y: cardRect.minY, width: maxSubW, height: cardRect.height)).addClip()
                    subStr.draw(at: NSPoint(x: subX, y: cardRect.midY - subSize.height * 0.5), withAttributes: subAttrs)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }

            let hintStr = "Edit ▾" as NSString
            let hintSize = hintStr.size(withAttributes: subAttrs)
            hintStr.draw(
                at: NSPoint(x: cardRect.maxX - hintSize.width - 12.0, y: cardRect.midY - hintSize.height * 0.5),
                withAttributes: subAttrs
            )

        case let .latexAbstractCard(fullBlockRange, dimFactor):
            let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
            guard blockGlyphs.location != NSNotFound else { return }
            var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockRect.origin.x = origin.x + 12.0
            blockRect.origin.y += origin.y
            blockRect.size.width = max(120.0, contentWidth - 24.0)

            let cardRect = blockRect.insetBy(dx: 0, dy: 2.0)
            let bg = currentTheme.codeBackgroundNSColor.withAlphaComponent(0.55 * dimFactor)
            bg.setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 6.0, yRadius: 6.0).fill()

            let hdrAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: effectiveFontSize * 0.78, weight: .bold),
                .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor),
                .kern: 1.1
            ]
            let hdr = "ABSTRACT" as NSString
            let hdrSize = hdr.size(withAttributes: hdrAttrs)
            hdr.draw(at: NSPoint(x: cardRect.midX - hdrSize.width * 0.5, y: cardRect.minY + 6.0), withAttributes: hdrAttrs)

        case let .latexTheoremCard(header, isProof, fullBlockRange, dimFactor):
            let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
            guard blockGlyphs.location != NSNotFound else { return }
            var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockRect.origin.x = origin.x
            blockRect.origin.y += origin.y
            blockRect.size.width = contentWidth

            let cardRect = blockRect.insetBy(dx: 0, dy: 2.0)
            let fillCol = isProof
                ? currentTheme.codeBackgroundNSColor.withAlphaComponent(0.32 * dimFactor)
                : currentTheme.linkNSColor.withAlphaComponent((currentTheme.isDark ? 0.08 : 0.05) * dimFactor)
            fillCol.setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 6.0, yRadius: 6.0).fill()

            let accentCol = (isProof ? currentTheme.secondaryTextNSColor : currentTheme.linkNSColor)
                .withAlphaComponent(0.75 * dimFactor)
            accentCol.setFill()
            let barRect = NSRect(x: cardRect.minX, y: cardRect.minY + 4.0, width: 3.0, height: max(8.0, cardRect.height - 8.0))
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()

            let hdrFont = isProof
                ? currentTheme.bodyFont(size: effectiveFontSize * 0.95, italic: true, semibold: true)
                : currentTheme.bodyFont(size: effectiveFontSize * 0.95, bold: true)
            let hdrAttrs: [NSAttributedString.Key: Any] = [
                .font: hdrFont,
                .foregroundColor: currentTheme.headingNSColor.withAlphaComponent(dimFactor)
            ]
            let hdrStr = (isProof ? "\(header)." : header) as NSString
            hdrStr.draw(at: NSPoint(x: cardRect.minX + 16.0, y: cardRect.minY + 5.0), withAttributes: hdrAttrs)

            if isProof {
                let qedStr = "∎" as NSString
                let qedSize = qedStr.size(withAttributes: hdrAttrs)
                qedStr.draw(
                    at: NSPoint(x: cardRect.maxX - qedSize.width - 14.0, y: cardRect.maxY - qedSize.height - 6.0),
                    withAttributes: hdrAttrs
                )
            }

        case let .latexInputCard(path, resolvedURL, _, dimFactor):
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let cardRect = NSRect(
                x: origin.x,
                y: origin.y + lineFrag.minY + 2.0,
                width: contentWidth,
                height: max(26.0, lineFrag.height - 4.0)
            )
            currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 6.0, yRadius: 6.0).fill()

            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10.0, weight: .semibold),
                .foregroundColor: currentTheme.linkNSColor.withAlphaComponent(dimFactor)
            ]
            let badgeStr = "↪ INCLUDE" as NSString
            let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
            badgeStr.draw(
                at: NSPoint(x: cardRect.minX + 12.0, y: cardRect.midY - badgeSize.height * 0.5),
                withAttributes: badgeAttrs
            )

            let pathAttrs: [NSAttributedString.Key: Any] = [
                .font: currentTheme.codeFont(size: 12.0),
                .foregroundColor: currentTheme.textNSColor.withAlphaComponent(dimFactor)
            ]
            let pathStr = path as NSString
            let pathSize = pathStr.size(withAttributes: pathAttrs)
            pathStr.draw(
                at: NSPoint(x: cardRect.minX + badgeSize.width + 24.0, y: cardRect.midY - pathSize.height * 0.5),
                withAttributes: pathAttrs
            )

            let statusText = (resolvedURL != nil ? "Open .tex →" : "Missing file") as NSString
            let statusSize = statusText.size(withAttributes: badgeAttrs)
            statusText.draw(
                at: NSPoint(x: cardRect.maxX - statusSize.width - 12.0, y: cardRect.midY - statusSize.height * 0.5),
                withAttributes: badgeAttrs
            )

        case let .latexEquationNumber(number, fullBlockRange, dimFactor):
            let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
            guard blockGlyphs.location != NSNotFound else { return }
            var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockRect.origin.y += origin.y
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: currentTheme.bodyFont(size: effectiveFontSize * 0.92),
                .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor)
            ]
            let numStr = number as NSString
            let numSize = numStr.size(withAttributes: numAttrs)
            numStr.draw(
                at: NSPoint(x: origin.x + contentWidth - numSize.width - 12.0, y: blockRect.midY - numSize.height * 0.5),
                withAttributes: numAttrs
            )

        case let .latexSectionBadge(number, level, _, dimFactor):
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let glyphLoc = layoutManager.location(forGlyphAt: glyphRange.location)
            let headingFont = currentTheme.headingFont(level: level, scale: typographySettings.fontSizeScale)
            let baselineY = origin.y + lineFrag.minY + glyphLoc.y
            let drawY = baselineY - headingFont.ascender
            let attrs: [NSAttributedString.Key: Any] = [
                .font: headingFont,
                .foregroundColor: currentTheme.linkNSColor.withAlphaComponent(0.88 * dimFactor)
            ]
            (number as NSString).draw(at: NSPoint(x: origin.x, y: drawY), withAttributes: attrs)

        case let .latexInlinePill(label, _, _, _, pillRange, fontSize, isCitation, dimFactor):
            guard let pillRect = computeLaTeXInlinePillRect(
                pillRange: pillRange,
                label: label,
                fontSize: fontSize,
                layoutManager: layoutManager,
                origin: origin
            ) else { return }
            let accent = isCitation ? currentTheme.linkNSColor : currentTheme.headingNSColor
            accent.withAlphaComponent((currentTheme.isDark ? 0.18 : 0.12) * dimFactor).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5).fill()

            let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: pillFont,
                .foregroundColor: accent.withAlphaComponent(dimFactor)
            ]
            let labelNS = label as NSString
            let textSize = labelNS.size(withAttributes: textAttrs)
            labelNS.draw(
                at: NSPoint(x: pillRect.midX - textSize.width * 0.5, y: pillRect.midY - textSize.height * 0.5),
                withAttributes: textAttrs
            )

        default:
            break
        }
    }

    func computeLaTeXInlinePillRect(
        pillRange: NSRange,
        label: String,
        fontSize: CGFloat,
        layoutManager: NSLayoutManager,
        origin: NSPoint
    ) -> NSRect? {
        guard pillRange.location != NSNotFound,
              pillRange.location < (self.string as NSString).length else { return nil }
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: pillRange.location)
        guard firstGlyph != NSNotFound, firstGlyph < layoutManager.numberOfGlyphs else { return nil }
        let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: firstGlyph, effectiveRange: nil)
        let glyphLoc = layoutManager.location(forGlyphAt: firstGlyph)
        let baselineY = origin.y + lineFrag.minY + glyphLoc.y

        let pillFont = NSFont.systemFont(ofSize: max(10.5, fontSize * 0.82), weight: .medium)
        let spanInfo = self.textStorage?.attribute(
            MarkdownLiveStyler.inlineMathSpanAttributeKey,
            at: pillRange.location,
            effectiveRange: nil
        ) as? MarkdownLiveStyler.InlineMathLayoutInfo
        let width = spanInfo?.width ?? (ceil((label as NSString).size(withAttributes: [.font: pillFont]).width) + 12.0)
        let height = pillFont.ascender + abs(pillFont.descender) + 3.0
        return NSRect(
            x: origin.x + lineFrag.minX + glyphLoc.x + 1.0,
            y: baselineY - pillFont.ascender - 1.5,
            width: max(14.0, width - 2.0),
            height: height
        )
    }
}
