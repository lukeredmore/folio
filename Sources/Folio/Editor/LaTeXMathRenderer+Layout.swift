import AppKit
import Foundation

private struct MathFontCacheKey: Hashable {
    let style: MathFontStyle
    let quantizedSize: Int
}

extension LaTeXMathRenderer {
    private static let fontCacheLock = NSLock()
    nonisolated(unsafe) private static var fontCache: [MathFontCacheKey: NSFont] = [:]

    // MARK: - 2D Box Layout Engine (Flipped NSView coordinates: +y is downward)
    static func font(for style: MathFontStyle, size: CGFloat) -> NSFont {
        let key = MathFontCacheKey(style: style, quantizedSize: Int((size * 100.0).rounded()))
        fontCacheLock.lock()
        if let cached = fontCache[key] {
            fontCacheLock.unlock()
            return cached
        }
        fontCacheLock.unlock()

        let resolved: NSFont
        switch style {
        case .italicVariable:
            resolved = NSFont(name: "Times New Roman Italic", size: size)
                ?? NSFont(name: "Georgia Italic", size: size)
                ?? NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
        case .romanUpright, .calligraphic, .blackboardBold:
            resolved = NSFont(name: "Times New Roman", size: size)
                ?? NSFont(name: "Georgia", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .boldUpright:
            resolved = NSFont(name: "Times New Roman Bold", size: size)
                ?? NSFont(name: "Georgia Bold", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .bold)
        case .monospace:
            resolved = NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
        case .operatorSymbol:
            resolved = NSFont(name: "Times New Roman", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .bigOperator:
            resolved = NSFont(name: "Times New Roman", size: size * 1.45)
                ?? NSFont.systemFont(ofSize: size * 1.45, weight: .light)
        }
        fontCacheLock.lock()
        fontCache[key] = resolved
        fontCacheLock.unlock()
        return resolved
    }

    static func layoutNode(
        _ node: MathNode,
        fontSize: CGFloat,
        isDisplay: Bool
    ) -> MathLayoutBox {
        let axisHeight = fontSize * 0.30

        switch node {
        case .space(let pts):
            let scaled = pts * (fontSize / 16.0)
            return MathLayoutBox(width: max(0, scaled), ascent: 0, descent: 0) { _, _, _ in }

        case .text(let str, let style):
            guard !str.isEmpty else {
                return MathLayoutBox(width: 0, ascent: 0, descent: 0) { _, _, _ in }
            }
            let f = font(for: style, size: fontSize)
            let nsStr = str as NSString
            let size = nsStr.size(withAttributes: [.font: f])
            let asc = f.ascender
            let desc = abs(f.descender)

            if style == .bigOperator {
                // Center big operator (∫, ∑, ∏) vertically on the math axis
                let totalH = asc + desc
                let halfH = totalH * 0.5
                let boxAsc = axisHeight + halfH * 0.85
                let boxDesc = max(4.0, totalH - boxAsc)
                return MathLayoutBox(width: size.width + 2.0, ascent: boxAsc, descent: boxDesc) { x, baselineY, color in
                    let drawY = baselineY - boxAsc
                    nsStr.draw(at: NSPoint(x: x, y: drawY), withAttributes: [
                        .font: f,
                        .foregroundColor: color
                    ])
                }
            }

            let extraRightItalicPad: CGFloat = (style == .italicVariable || style == .calligraphic) ? 1.2 : 0.0
            return MathLayoutBox(width: size.width + extraRightItalicPad, ascent: asc, descent: desc) { x, baselineY, color in
                let drawY = baselineY - asc
                nsStr.draw(at: NSPoint(x: x, y: drawY), withAttributes: [
                    .font: f,
                    .foregroundColor: color
                ])
            }

        case .row(let children):
            let childBoxes = children.map { layoutNode($0, fontSize: fontSize, isDisplay: isDisplay) }
            let totalWidth = childBoxes.reduce(0) { $0 + $1.width }
            let maxAsc = childBoxes.map(\.ascent).max() ?? (fontSize * 0.75)
            let maxDesc = childBoxes.map(\.descent).max() ?? (fontSize * 0.25)

            return MathLayoutBox(width: totalWidth, ascent: maxAsc, descent: maxDesc) { x, baselineY, color in
                var curX = x
                for box in childBoxes {
                    box.drawBox(curX, baselineY, color)
                    curX += box.width
                }
            }

        case .fraction(let numerator, let denominator):
            let childFontSize = max(10.0, fontSize * (isDisplay ? 0.82 : 0.74))
            let numBox = layoutNode(numerator, fontSize: childFontSize, isDisplay: false)
            let denBox = layoutNode(denominator, fontSize: childFontSize, isDisplay: false)

            let hPad: CGFloat = isDisplay ? 5.0 : 3.5
            let barWidth = max(numBox.width, denBox.width) + hPad * 2
            let gap: CGFloat = isDisplay ? 2.5 : 1.5
            let barThickness: CGFloat = max(1.0, fontSize * 0.06)

            // In flipped view: above baseline is +ascent, below baseline is +descent
            let totalAscent = axisHeight + gap + numBox.totalHeight
            let totalDescent = max(2.0, (denBox.totalHeight + gap) - axisHeight)

            return MathLayoutBox(
                width: barWidth + 3.0,
                ascent: totalAscent,
                descent: totalDescent
            ) { x, baselineY, color in
                let innerX = x + 1.5
                let axisY = baselineY - axisHeight

                // Draw horizontal fraction bar
                color.setFill()
                let barRect = NSRect(x: innerX, y: axisY - barThickness * 0.5, width: barWidth, height: barThickness)
                barRect.fill()

                // Draw numerator centered above the bar
                let numX = innerX + (barWidth - numBox.width) * 0.5
                let numBaselineY = axisY - gap - numBox.descent
                numBox.drawBox(numX, numBaselineY, color)

                // Draw denominator centered below the bar
                let denX = innerX + (barWidth - denBox.width) * 0.5
                let denBaselineY = axisY + gap + denBox.ascent
                denBox.drawBox(denX, denBaselineY, color)
            }

        case .sqrt(let radicand):
            let radBox = layoutNode(radicand, fontSize: fontSize * 0.95, isDisplay: isDisplay)
            let hookWidth: CGFloat = fontSize * 0.55
            let topGap: CGFloat = 2.5
            let barThickness: CGFloat = max(1.0, fontSize * 0.058)
            let asc = radBox.ascent + topGap + barThickness + 1.0
            let desc = radBox.descent + 1.0
            let totalWidth = hookWidth + radBox.width + 3.0

            return MathLayoutBox(width: totalWidth, ascent: asc, descent: desc) { x, baselineY, color in
                let topY = baselineY - radBox.ascent - topGap
                let bottomY = baselineY + radBox.descent

                let path = NSBezierPath()
                path.lineWidth = barThickness
                path.lineCapStyle = .round
                path.lineJoinStyle = .round

                // Radical checkmark + vinculum bar
                path.move(to: NSPoint(x: x + 1.0, y: topY + (bottomY - topY) * 0.55))
                path.line(to: NSPoint(x: x + hookWidth * 0.42, y: bottomY))
                path.line(to: NSPoint(x: x + hookWidth, y: topY))
                path.line(to: NSPoint(x: x + hookWidth + radBox.width + 2.0, y: topY))
                color.setStroke()
                path.stroke()

                radBox.drawBox(x + hookWidth + 1.0, baselineY, color)
            }

        case .scripts(let base, let subNode, let supNode):
            let baseBox = layoutNode(base, fontSize: fontSize, isDisplay: isDisplay)
            let scriptFontSize = max(9.0, fontSize * 0.68)
            let subBox = subNode.map { layoutNode($0, fontSize: scriptFontSize, isDisplay: false) }
            let supBox = supNode.map { layoutNode($0, fontSize: scriptFontSize, isDisplay: false) }

            let isBigOp: Bool = {
                if case .text(_, .bigOperator) = base { return true }
                return false
            }()

            let supShiftUp = isBigOp
                ? max(fontSize * 0.55, baseBox.ascent - (supBox?.descent ?? 0) * 0.4)
                : max(fontSize * 0.36, baseBox.ascent * 0.55)
            let subShiftDown = isBigOp
                ? max(fontSize * 0.48, baseBox.descent + (subBox?.ascent ?? 0) * 0.55)
                : max(fontSize * 0.22, baseBox.descent * 0.65 + fontSize * 0.16)

            let scriptWidth = max(subBox?.width ?? 0, supBox?.width ?? 0)
            let newAsc = max(baseBox.ascent, supBox != nil ? supShiftUp + supBox!.ascent : 0)
            let newDesc = max(baseBox.descent, subBox != nil ? subShiftDown + subBox!.descent : 0)

            return MathLayoutBox(
                width: baseBox.width + scriptWidth + 1.5,
                ascent: newAsc,
                descent: newDesc
            ) { x, baselineY, color in
                baseBox.drawBox(x, baselineY, color)
                let scriptX = x + baseBox.width + (isBigOp ? 0.5 : 0.0)
                if let supBox = supBox {
                    supBox.drawBox(scriptX, baselineY - supShiftUp, color)
                }
                if let subBox = subBox {
                    let subOffset: CGFloat = isBigOp ? -1.5 : 0.0
                    subBox.drawBox(scriptX + subOffset, baselineY + subShiftDown, color)
                }
            }

        case .delimited(let left, let body, let right):
            let bodyBox = layoutNode(body, fontSize: fontSize, isDisplay: isDisplay)
            let halfSpan = max(bodyBox.ascent - axisHeight, bodyBox.descent + axisHeight) + 2.0
            let delimAsc = axisHeight + halfSpan
            let delimDesc = max(2.0, halfSpan - axisHeight)
            let delimW: CGFloat = left.isEmpty ? 0 : max(6.0, fontSize * 0.38)
            let rightDelimW: CGFloat = right.isEmpty ? 0 : max(6.0, fontSize * 0.38)

            return MathLayoutBox(
                width: delimW + bodyBox.width + rightDelimW + 2.0,
                ascent: delimAsc,
                descent: delimDesc
            ) { x, baselineY, color in
                let topY = baselineY - delimAsc + 1.5
                let botY = baselineY + delimDesc - 1.5

                if !left.isEmpty {
                    drawTallDelimiter(left, x: x + 1.0, topY: topY, bottomY: botY, width: delimW - 1.5, color: color)
                }
                bodyBox.drawBox(x + delimW + 1.0, baselineY, color)
                if !right.isEmpty {
                    drawTallDelimiter(right, x: x + delimW + bodyBox.width + 1.5, topY: topY, bottomY: botY, width: rightDelimW - 1.5, color: color)
                }
            }

        case .accent(let base, let mark):
            let baseBox = layoutNode(base, fontSize: fontSize, isDisplay: isDisplay)
            let f = font(for: .operatorSymbol, size: fontSize)
            return MathLayoutBox(
                width: baseBox.width,
                ascent: baseBox.ascent + fontSize * 0.22,
                descent: baseBox.descent
            ) { x, baselineY, color in
                baseBox.drawBox(x, baselineY, color)
                let markStr = mark as NSString
                markStr.draw(
                    at: NSPoint(x: x + baseBox.width * 0.35, y: baselineY - baseBox.ascent - fontSize * 0.55),
                    withAttributes: [.font: f, .foregroundColor: color]
                )
            }
        }
    }

    static func drawTallDelimiter(
        _ symbol: String,
        x: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        width: CGFloat,
        color: NSColor
    ) {
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        let midY = (topY + bottomY) * 0.5

        switch symbol {
        case "(":
            path.move(to: NSPoint(x: x + width, y: topY))
            path.curve(
                to: NSPoint(x: x + width, y: bottomY),
                controlPoint1: NSPoint(x: x - 1.0, y: topY + (bottomY - topY) * 0.22),
                controlPoint2: NSPoint(x: x - 1.0, y: topY + (bottomY - topY) * 0.78)
            )
        case ")":
            path.move(to: NSPoint(x: x, y: topY))
            path.curve(
                to: NSPoint(x: x, y: bottomY),
                controlPoint1: NSPoint(x: x + width + 1.0, y: topY + (bottomY - topY) * 0.22),
                controlPoint2: NSPoint(x: x + width + 1.0, y: topY + (bottomY - topY) * 0.78)
            )
        case "[":
            path.move(to: NSPoint(x: x + width, y: topY))
            path.line(to: NSPoint(x: x + 1.0, y: topY))
            path.line(to: NSPoint(x: x + 1.0, y: bottomY))
            path.line(to: NSPoint(x: x + width, y: bottomY))
        case "]":
            path.move(to: NSPoint(x: x, y: topY))
            path.line(to: NSPoint(x: x + width - 1.0, y: topY))
            path.line(to: NSPoint(x: x + width - 1.0, y: bottomY))
            path.line(to: NSPoint(x: x, y: bottomY))
        default:
            path.move(to: NSPoint(x: x + width * 0.5, y: topY))
            path.line(to: NSPoint(x: x + width * 0.5, y: midY))
            path.line(to: NSPoint(x: x + width * 0.5, y: bottomY))
        }

        color.setStroke()
        path.stroke()
    }
}
