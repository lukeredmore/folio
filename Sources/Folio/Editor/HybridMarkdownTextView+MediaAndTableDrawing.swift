import AppKit
import SwiftUI

extension HybridMarkdownTextView {

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
            let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
            guard blockGlyphs.location != NSNotFound else { return }
            var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockRect.origin.x = origin.x
            blockRect.origin.y += origin.y
            blockRect.size.width = contentWidth

            let cardRect = blockRect.insetBy(dx: 0, dy: 3)
            currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 8.0, yRadius: 8.0).fill()

            let diagramKey = DiagramImageRenderer.Key(kind: .mermaid(isDark: currentTheme.isDark), source: mermaidSource)
            let img = DiagramImageRenderer.shared.image(for: diagramKey, prioritize: true)
            let innerRect = cardRect.insetBy(dx: 16.0, dy: 12.0)
            if let img = img, img.size.width > 0, img.size.height > 0, innerRect.width > 10, innerRect.height > 10 {
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
                drawDiagramPlaceholder(in: innerRect, key: diagramKey, dimFactor: dimFactor)
            }

            // Draw subtle "MERMAID" badge in top-right corner
            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
            ]
            drawDiagramExpandButton(in: cardRect, dimFactor: dimFactor)
            let badgeStr = "MERMAID" as NSString
            let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
            badgeStr.draw(
                at: NSPoint(x: cardRect.maxX - badgeSize.width - 10.0, y: cardRect.minY + 6.0),
                withAttributes: badgeAttrs
            )

        case let .svgBlockRendered(svgSource, fullBlockRange, dimFactor):
            let blockGlyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
            guard blockGlyphs.location != NSNotFound else { return }
            var blockRect = layoutManager.boundingRect(forGlyphRange: blockGlyphs, in: textContainer)
            blockRect.origin.x = origin.x
            blockRect.origin.y += origin.y
            blockRect.size.width = contentWidth

            let cardRect = blockRect.insetBy(dx: 0, dy: 3)
            currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 8.0, yRadius: 8.0).fill()

            let diagramKey = DiagramImageRenderer.Key(kind: .svg, source: svgSource)
            let img = DiagramImageRenderer.shared.image(for: diagramKey, prioritize: true)
            let innerRect = cardRect.insetBy(dx: 16.0, dy: 12.0)
            if let img = img, img.size.width > 0, img.size.height > 0, innerRect.width > 10, innerRect.height > 10 {
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
                drawDiagramPlaceholder(in: innerRect, key: diagramKey, dimFactor: dimFactor)
            }

            let badgeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
                .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
            ]
            let badgeStr = "SVG" as NSString
            let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
            badgeStr.draw(
                at: NSPoint(x: cardRect.maxX - badgeSize.width - 10.0, y: cardRect.minY + 6.0),
                withAttributes: badgeAttrs
            )

        case let .imageRendered(url, alt, fullRange, explicitWidth, explicitHeight, baseDirectoryURL, dimFactor):
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let imgGlyphIdx = layoutManager.glyphIndexForCharacter(at: fullRange.location)
            let glyphX = (imgGlyphIdx != NSNotFound && imgGlyphIdx < layoutManager.numberOfGlyphs)
                ? layoutManager.location(forGlyphAt: imgGlyphIdx).x
                : 0.0
            let lineKey = dec.lineRange.location
            let currentOffset = imageXOffsetByLineLocation[lineKey] ?? 0.0
            let startX = origin.x + max(glyphX, currentOffset)
            let remainingWidth = max(80.0, (origin.x + contentWidth) - startX)

            let isVideo = FolioMediaImageCache.shared.isKnownVideo(for: url, baseDirectoryURL: baseDirectoryURL)
            let loadedImg = animatedMediaFrame(
                for: url,
                baseDirectoryURL: baseDirectoryURL,
                isDark: currentTheme.isDark
            )

            if let img = loadedImg, img.size.width > 0, img.size.height > 0 {
                let intrinsicSize = img.size
                let aspect = intrinsicSize.height / max(1.0, intrinsicSize.width)
                let targetW: CGFloat
                let targetH: CGFloat
                if let ew = explicitWidth, let eh = explicitHeight {
                    targetW = ew
                    targetH = eh
                } else if let ew = explicitWidth {
                    targetW = ew
                    targetH = round(ew * aspect)
                } else if let eh = explicitHeight {
                    targetH = eh
                    targetW = round(eh / max(0.01, aspect))
                } else {
                    targetW = intrinsicSize.width
                    targetH = intrinsicSize.height
                }
                let maxDrawH = max(18.0, lineFrag.height - 6.0)
                let scale = min(1.0, min(remainingWidth / max(1.0, targetW), maxDrawH / max(1.0, targetH)))
                let drawW = targetW * scale
                let drawH = targetH * scale
                let drawRect = NSRect(
                    x: startX,
                    y: origin.y + lineFrag.minY + (lineFrag.height - drawH) * 0.5,
                    width: drawW,
                    height: drawH
                )
                updateInlineVideoFrameIfActive(for: url, fullRange: fullRange, drawRect: drawRect)
                DiagramImageRenderer.drawCached(img, in: drawRect, fraction: dimFactor)

                if isVideo {
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
                imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + drawW + 8.0
            } else {
                // Compact placeholder card for pending/missing image or video
                let cardWidth = min(remainingWidth, max(200.0, min(380.0, explicitWidth ?? 360.0)))
                let cardHeight = min(50.0, max(38.0, lineFrag.height - 6.0))
                let cardRect = NSRect(
                    x: startX,
                    y: origin.y + lineFrag.minY + (lineFrag.height - cardHeight) * 0.5,
                    width: cardWidth,
                    height: cardHeight
                )
                imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + cardWidth + 8.0

                currentTheme.codeBackgroundNSColor.withAlphaComponent(dimFactor).setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 7.0, yRadius: 7.0).fill()

                let cardBorder = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.10 * dimFactor)
                    : NSColor.black.withAlphaComponent(0.08 * dimFactor)
                cardBorder.setStroke()
                let strokePath = NSBezierPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.0, yRadius: 7.0)
                strokePath.lineWidth = 1.0
                strokePath.stroke()

                let badgeLabel = isVideo ? "▶ VIDEO" : "IMAGE"
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: currentTheme.linkNSColor.withAlphaComponent(dimFactor)
                ]
                let badgeStr = badgeLabel as NSString
                let badgeSize = badgeStr.size(withAttributes: badgeAttrs)
                let pillRect = NSRect(
                    x: cardRect.minX + 12.0,
                    y: cardRect.midY - badgeSize.height * 0.5 - 3.0,
                    width: badgeSize.width + 12.0,
                    height: badgeSize.height + 6.0
                )
                currentTheme.linkNSColor.withAlphaComponent(0.14 * dimFactor).setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: 4.5, yRadius: 4.5).fill()
                badgeStr.draw(
                    at: NSPoint(x: pillRect.minX + 6.0, y: pillRect.minY + 3.0),
                    withAttributes: badgeAttrs
                )

                let titleText = alt.isEmpty ? (url as NSString).lastPathComponent : alt
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: currentTheme.bodyFont(size: 12.0, bold: true),
                    .foregroundColor: currentTheme.textNSColor.withAlphaComponent(dimFactor)
                ]
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: currentTheme.codeFont(size: 10.5),
                    .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(dimFactor * 0.85)
                ]
                let textX = pillRect.maxX + 10.0
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cardRect.insetBy(dx: 8.0, dy: 2.0)).addClip()
                (titleText as NSString).draw(
                    at: NSPoint(x: textX, y: cardRect.midY - 14.0),
                    withAttributes: titleAttrs
                )
                (url as NSString).draw(
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
            let hrColor = currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.18)
                : NSColor.black.withAlphaComponent(0.13)
            hrColor.setFill()
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let midY = origin.y + lineFrag.minY + lineFrag.height * 0.5 + 2.0
            let hrRect = NSRect(x: origin.x, y: midY - 0.75, width: contentWidth, height: 1.5)
            NSBezierPath(roundedRect: hrRect, xRadius: 0.75, yRadius: 0.75).fill()

        case let .tableRow(isHeader, isSeparator, isFirstRow, isLastRow, bodyRowIndex, tableOffsetX, tableWidth, columnDividers):
            // Allow wide tables to exceed `contentWidth` without clamping!
            let effectiveWidth = max(tableWidth, 240.0)
            // Wide tables get their own line fragment (WideBlockTextContainer); draw from its edge.
            let rowFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let startX = origin.x + rowFragment.minX
                + (tableOffsetX > 0 ? tableOffsetX : max(0.0, floor((min(contentWidth, rowFragment.width) - effectiveWidth) * 0.5)))
            let usedFrag = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let rowY = origin.y + usedFrag.minY
            let rowH = max(isSeparator ? 2.0 : 32.0, usedFrag.height)
            let rowRect = NSRect(x: startX, y: rowY, width: effectiveWidth, height: rowH)
            let outerBorderColor = currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.11)
            let innerGridColor = currentTheme.isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.065)

            if isSeparator {
                // Draw crisp horizontal separator line between header and body
                let headerDividerColor = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.15)
                headerDividerColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.midY - 0.5, width: effectiveWidth, height: 1.0).fill()

                // Left and right outer borders across separator
                outerBorderColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                NSRect(x: rowRect.maxX - 1.0, y: rowRect.minY, width: 1.0, height: rowRect.height).fill()
                return
            }

            // Background tint for header or alternating body rows
            if isHeader {
                let headerBg = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.038)
                headerBg.setFill()
                rowRect.fill()
            } else if bodyRowIndex % 2 == 1 {
                let stripeBg = currentTheme.isDark
                    ? NSColor.white.withAlphaComponent(0.025)
                    : NSColor.black.withAlphaComponent(0.016)
                stripeBg.setFill()
                rowRect.fill()
            }

            // Subtle vertical column dividers
            innerGridColor.setFill()
            for divX in columnDividers where divX < effectiveWidth - 4.0 {
                let colLineRect = NSRect(x: startX + divX, y: rowRect.minY, width: 1.0, height: rowRect.height)
                colLineRect.fill()
            }

            // Subtle horizontal divider at the bottom of each non-last body row
            if !isHeader && !isLastRow {
                innerGridColor.setFill()
                NSRect(x: rowRect.minX, y: rowRect.maxY - 0.5, width: effectiveWidth, height: 0.75).fill()
            }

            // Outer table frame edges (top on first row, bottom on last row, left & right on all rows)
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
            break
        }
    }
}
