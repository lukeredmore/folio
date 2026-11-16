import AppKit
import SwiftUI

extension HybridMarkdownTextView {

    func drawDiagramPlaceholder(in rect: NSRect, key: DiagramImageRenderer.Key, dimFactor: CGFloat) {
        let message = DiagramImageRenderer.shared.isPending(key) ? "Rendering diagram…" : "Diagram could not be rendered"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(0.8 * dimFactor)
        ]
        let text = message as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawDiagramBlockCard(
        key: DiagramImageRenderer.Key,
        badgeTitle: String,
        showsExpandButton: Bool,
        fullBlockRange: NSRange,
        dimFactor: CGFloat
    ) {
        guard let cardRect = diagramCardRect(for: fullBlockRange) else { return }
        currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
        NSBezierPath(roundedRect: cardRect, xRadius: 8.0, yRadius: 8.0).fill()

        let img = DiagramImageRenderer.shared.image(for: key, prioritize: true)
        let innerRect = cardRect.insetBy(dx: 16.0, dy: 12.0)
        if let img, img.size.width > 0, img.size.height > 0, innerRect.width > 10, innerRect.height > 10 {
            let intrinsicSize = img.size
            let scale = min(1.0, min(innerRect.width / intrinsicSize.width, innerRect.height / intrinsicSize.height))
            let drawW = intrinsicSize.width * scale
            let drawH = intrinsicSize.height * scale
            let drawRect = NSRect(
                x: innerRect.midX - drawW * 0.5,
                y: innerRect.midY - drawH * 0.5,
                width: drawW,
                height: drawH
            )
            DiagramImageRenderer.drawCached(img, in: drawRect, fraction: dimFactor)
        } else {
            drawDiagramPlaceholder(in: innerRect, key: key, dimFactor: dimFactor)
        }

        if showsExpandButton {
            drawDiagramExpandButton(in: cardRect, dimFactor: dimFactor)
        }
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
        ]
        let badgeStr = badgeTitle as NSString
        let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
        badgeStr.draw(
            at: NSPoint(x: cardRect.maxX - badgeSize.width - 10.0, y: cardRect.minY + 6.0),
            withAttributes: badgeAttrs
        )
    }

    func drawMediaAndBlockDecoration(
        _ dec: LineDecoration,
        glyphRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: NSPoint,
        contentWidth: CGFloat,
        imageXOffsetByLineLocation: inout [Int: CGFloat]
    ) {
        switch dec.kind {
        case let .mermaidBlockRendered(mermaidSource, fullBlockRange, dimFactor):
            drawDiagramBlockCard(
                key: DiagramImageRenderer.Key(kind: .mermaid(isDark: currentTheme.isDark), source: mermaidSource),
                badgeTitle: "MERMAID",
                showsExpandButton: true,
                fullBlockRange: fullBlockRange,
                dimFactor: dimFactor
            )

        case let .svgBlockRendered(svgSource, fullBlockRange, dimFactor):
            drawDiagramBlockCard(
                key: DiagramImageRenderer.Key(kind: .svg, source: svgSource),
                badgeTitle: "SVG",
                showsExpandButton: false,
                fullBlockRange: fullBlockRange,
                dimFactor: dimFactor
            )

        case let .htmlBlockRendered(htmlSource, fullBlockRange, layoutWidth, dimFactor):
            drawHTMLBlockFallback(
                source: htmlSource,
                fullBlockRange: fullBlockRange,
                layoutWidth: layoutWidth,
                dirtyRect: bounds,
                dimFactor: dimFactor
            )

        case let .imageRendered(url, alt, fullRange, _, _, baseDirectoryURL, dimFactor):
            guard
                let layout = resolveMediaCardLayout(
                    for: dec,
                    glyphRange: glyphRange,
                    advanceAnimation: true,
                    layoutManager: layoutManager,
                    origin: origin,
                    contentWidth: contentWidth,
                    imageXOffsetByLineLocation: &imageXOffsetByLineLocation
                )
            else {
                return
            }

            if let img = layout.image {
                let drawRect = layout.rect
                updateInlineVideoFrameIfActive(for: url, fullRange: fullRange, drawRect: drawRect)
                DiagramImageRenderer.drawCached(img, in: drawRect, fraction: dimFactor)

                if FolioMediaImageCache.shared.isKnownVideo(for: url, baseDirectoryURL: baseDirectoryURL) {
                    let circleRadius: CGFloat = 20.0
                    let circleRect = NSRect(
                        x: drawRect.midX - circleRadius,
                        y: drawRect.midY - circleRadius,
                        width: circleRadius * 2.0,
                        height: circleRadius * 2.0
                    )
                    NSColor.black.withAlphaComponent(0.62 * dimFactor).setFill()
                    NSBezierPath(ovalIn: circleRect).fill()

                    let playTriangle = NSBezierPath()
                    playTriangle.move(to: NSPoint(x: drawRect.midX - 5.0, y: drawRect.midY - 7.5))
                    playTriangle.line(to: NSPoint(x: drawRect.midX - 5.0, y: drawRect.midY + 7.5))
                    playTriangle.line(to: NSPoint(x: drawRect.midX + 8.0, y: drawRect.midY))
                    playTriangle.close()
                    NSColor.white.withAlphaComponent(0.95 * dimFactor).setFill()
                    playTriangle.fill()
                }
            } else {
                let cardRect = layout.rect
                let placeholder = FolioMediaImageCache.shared.placeholderInfo(
                    for: url,
                    alt: alt,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: currentTheme.isDark
                )
                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 7.0, yRadius: 7.0).fill()

                let warningAccent =
                    currentTheme.isDark
                    ? NSColor(srgbRed: 0.96, green: 0.62, blue: 0.24, alpha: 1.0)
                    : NSColor(srgbRed: 0.80, green: 0.38, blue: 0.06, alpha: 1.0)
                let borderAccent = (placeholder.isError ? warningAccent : currentTheme.linkNSColor)
                    .withAlphaComponent(dimFactor)

                let cardBorder =
                    placeholder.isError
                    ? borderAccent.withAlphaComponent(0.38 * dimFactor)
                    : (currentTheme.isDark
                        ? NSColor.white.withAlphaComponent(0.10 * dimFactor)
                        : NSColor.black.withAlphaComponent(0.08 * dimFactor))
                cardBorder.setStroke()
                let strokePath = NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.0, yRadius: 7.0)
                strokePath.lineWidth = 1.0
                if placeholder.isError {
                    let pattern: [CGFloat] = [4.0, 3.0]
                    strokePath.setLineDash(pattern, count: pattern.count, phase: 0)
                }
                strokePath.stroke()

                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: currentTheme.bodyFont(size: 12.0, bold: true),
                    .foregroundColor: currentTheme.textNSColor.withAlphaComponent(dimFactor)
                ]
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: currentTheme.codeFont(size: 10.5),
                    .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
                ]
                let textX = cardRect.minX + 12.0
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cardRect.insetBy(dx: 8.0, dy: 2.0)).addClip()
                (placeholder.titleText as NSString).draw(
                    at: NSPoint(x: textX, y: cardRect.midY - 14.0),
                    withAttributes: titleAttrs
                )
                (placeholder.subtitleText as NSString).draw(
                    at: NSPoint(x: textX, y: cardRect.midY + 1.0),
                    withAttributes: subAttrs
                )
                NSGraphicsContext.restoreGraphicsState()
            }

        case let .listBullet(bulletRange, dimFactor):
            let bulletGlyphs = layoutManager.glyphRange(forCharacterRange: bulletRange, actualCharacterRange: nil)
            guard bulletGlyphs.location != NSNotFound else { return }
            var bulletRect = layoutManager.boundingRect(forGlyphRange: bulletGlyphs, in: textContainer)
            bulletRect.origin.x += origin.x
            bulletRect.origin.y += origin.y

            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: bulletGlyphs.location, effectiveRange: nil)
            let glyphLoc = layoutManager.location(forGlyphAt: bulletGlyphs.location)
            let baselineY = origin.y + lineFrag.minY + glyphLoc.y
            let baseFont = currentTheme.bodyFont(size: currentTheme.baseFontSize * typographySettings.fontSizeScale)
            let midY = baselineY - (baseFont.ascender + baseFont.descender) * 0.5
            let dotDiameter: CGFloat = 5.5
            let dotRect = NSRect(
                x: bulletRect.midX - dotDiameter * 0.5,
                y: midY - dotDiameter * 0.5,
                width: dotDiameter,
                height: dotDiameter
            )
            currentTheme.linkNSColor.withAlphaComponent(dimFactor).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

        case .horizontalRule:
            let hrColor =
                currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.13)
            hrColor.setFill()
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let midY = origin.y + lineFrag.minY + lineFrag.height * 0.5 + 2.0
            let hrRect = NSRect(x: origin.x, y: midY - 0.75, width: contentWidth, height: 1.5)
            NSBezierPath(roundedRect: hrRect, xRadius: 0.75, yRadius: 0.75).fill()

        case let .tableRow(isHeader, isSeparator, isFirstRow, isLastRow, bodyRowIndex, tableOffsetX, tableWidth, columnDividers):
            let effectiveWidth = max(tableWidth, 240.0)
            let rowFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let startX =
                origin.x + rowFragment.minX
                + (tableOffsetX > 0 ? tableOffsetX : max(0.0, floor((min(contentWidth, rowFragment.width) - effectiveWidth) * 0.5)))
            let usedFrag = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let rowY = origin.y + usedFrag.minY
            let rowH = max(isSeparator ? 2.0 : 32.0, usedFrag.height)
            let rowRect = NSRect(x: startX, y: rowY, width: effectiveWidth, height: rowH)
            let outerBorderColor =
                currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.11)
            let innerGridColor =
                currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.065)

            if isSeparator {
                let headerDividerColor =
                    currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.15)
                headerDividerColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.midY - 0.5, width: effectiveWidth, height: 1.0).fill()

                outerBorderColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                NSRect(x: rowRect.maxX - 1.0, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                return
            }

            if isHeader {
                let headerBg =
                    currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.038)
                headerBg.setFill()
                rowRect.fill()
            } else if bodyRowIndex % 2 == 1 {
                let stripeBg =
                    currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.025)
                    : NSColor.black.withAlphaComponent(0.016)
                stripeBg.setFill()
                rowRect.fill()
            }

            innerGridColor.setFill()
            for divX in columnDividers where divX < effectiveWidth - 4.0 {
                let colLineRect = NSRect(x: startX + divX, y: rowRect.minY, width: 1.0, height: rowRect.height)
                colLineRect.fill()
            }

            if !isHeader && !isLastRow {
                innerGridColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.maxY - 0.5, width: effectiveWidth, height: 0.75).fill()
            }

            outerBorderColor.setFill()
            NSRect(x: rowRect.minX, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
            NSRect(x: rowRect.maxX - 1.0, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
            if isFirstRow {
                NSRect(x: rowRect.minX, y: rowRect.minY, width: effectiveWidth, height: 1.0).fill()
            }
            if isLastRow {
                NSRect(x: rowRect.minX, y: rowRect.maxY - 1.0, width: effectiveWidth, height: 1.0).fill()
            }

        default:
            drawLaTeXDecoration(
                dec, glyphRange: glyphRange, layoutManager: layoutManager, textContainer: textContainer, origin: origin, contentWidth: contentWidth)
        }
    }
}
