import AppKit
import Foundation
import FolioEngineFFI

public enum MathFontStyle: Equatable {
    case italicVariable, romanUpright, boldUpright, calligraphic
    case blackboardBold, monospace, operatorSymbol, bigOperator

    public static func fromEngineCode(_ code: UInt32) -> MathFontStyle {
        switch code {
        case 0: return .italicVariable
        case 1: return .romanUpright
        case 2: return .boldUpright
        case 3: return .calligraphic
        case 4: return .blackboardBold
        case 5: return .monospace
        case 6: return .operatorSymbol
        case 7: return .bigOperator
        default: return .romanUpright
        }
    }
}

public struct MathLayoutBox {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let tag: String?
    public let usesNativeOpenTypeMath: Bool
    public let drawBox: (_ x: CGFloat, _ baselineY: CGFloat, _ color: NSColor) -> Void

    public init(
        width: CGFloat, ascent: CGFloat, descent: CGFloat, tag: String? = nil,
        usesNativeOpenTypeMath: Bool = false,
        drawBox: @escaping (_ x: CGFloat, _ baselineY: CGFloat, _ color: NSColor) -> Void
    ) {
        self.width = width; self.ascent = ascent; self.descent = descent
        self.tag = tag; self.usesNativeOpenTypeMath = usesNativeOpenTypeMath
        self.drawBox = drawBox
    }

    public var totalHeight: CGFloat { ascent + descent }
}

enum CapturedEngineDrawCmd {
    case text(x: CGFloat, y: CGFloat, text: String, style: MathFontStyle, fontSize: CGFloat)
    case rule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
}

private struct MathFontCacheKey: Hashable {
    let style: MathFontStyle
    let quantizedSize: Int
}

public final class LaTeXMathRenderer {
    private static let fontCacheLock = NSLock()
    nonisolated(unsafe) private static var fallbackFontCache: [MathFontCacheKey: NSFont] = [:]

    /// Executes 2D math parsing and OpenType MATH layout via SwiftMath, falling back to the Rust core engine if incomplete.
    public static func layoutLatex(
        _ latex: String,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool,
        macros: [String: LaTeXMacroDefinition]? = nil
    ) -> MathLayoutBox {
        if let nativeBox = layoutWithSwiftMath(
            latex,
            baseFontSize: baseFontSize,
            isDisplayStyle: isDisplayStyle,
            macros: macros
        ) {
            return nativeBox
        }
        var effectiveMacros = currentDocumentMacros()
        if let macros {
            for (k, v) in macros { effectiveMacros[k] = v }
        }
        let (expanded, tag) = LaTeXMacroExpander.expandAndNormalize(latex, macros: effectiveMacros)
        return layoutWithFallbackEngine(
            expanded.isEmpty ? latex : expanded,
            baseFontSize: baseFontSize,
            isDisplayStyle: isDisplayStyle,
            tag: tag
        )
    }

    public static func layoutWithFallbackEngine(
        _ latex: String,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool,
        tag: String? = nil
    ) -> MathLayoutBox {
        let rawPtr = latex.withCString { cStr in
            ot_engine_layout_latex(cStr, Double(baseFontSize), isDisplayStyle)
        }
        guard let ptr = rawPtr else {
            return MathLayoutBox(width: 0, ascent: baseFontSize * 0.72, descent: baseFontSize * 0.22, tag: tag) { _, _, _ in }
        }
        defer { ot_engine_free_math_layout(ptr) }

        let res = ptr.pointee
        var captured: [CapturedEngineDrawCmd] = []
        if let cmdsPtr = res.commands, res.command_count > 0 {
            let buffer = UnsafeBufferPointer(start: cmdsPtr, count: res.command_count)
            captured.reserveCapacity(res.command_count)
            for cmd in buffer {
                switch cmd.kind {
                case 0:
                    let str = cmd.text != nil ? String(cString: cmd.text) : ""
                    captured.append(.text(
                        x: CGFloat(cmd.x), y: CGFloat(cmd.y), text: str,
                        style: MathFontStyle.fromEngineCode(cmd.font_style), fontSize: CGFloat(cmd.font_size)
                    ))
                case 1:
                    captured.append(.rule(
                        x: CGFloat(cmd.x), y: CGFloat(cmd.y), width: CGFloat(cmd.width), height: CGFloat(cmd.height)
                    ))
                default:
                    break
                }
            }
        }

        return MathLayoutBox(
            width: CGFloat(res.width), ascent: CGFloat(res.ascent), descent: CGFloat(res.descent),
            tag: tag, usesNativeOpenTypeMath: false
        ) { originX, baselineY, color in
            for item in captured {
                switch item {
                case let .text(dx, dy, text, style, fontSize):
                    let f = font(for: style, size: fontSize)
                    (text as NSString).draw(
                        at: NSPoint(x: originX + dx, y: baselineY + dy),
                        withAttributes: [.font: f, .foregroundColor: color]
                    )
                case let .rule(dx, dy, width, height):
                    color.setFill()
                    NSRect(x: originX + dx, y: baselineY + dy, width: width, height: height).fill()
                }
            }
        }
    }

    /// Converts a LaTeX expression to a readable plain/Unicode representation via the Rust core engine
    public static func plainTextSummary(of latex: String) -> String {
        let cOut = latex.withCString { cStr in
            ot_engine_plain_text_latex(cStr)
        }
        guard let ptr = cOut else {
            return latex
        }
        defer { ot_engine_free_string(ptr) }
        return String(cString: ptr)
    }

    static func font(for style: MathFontStyle, size: CGFloat) -> NSFont {
        let key = MathFontCacheKey(style: style, quantizedSize: Int((size * 100.0).rounded()))
        fontCacheLock.lock()
        if let cached = fallbackFontCache[key] {
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
        fallbackFontCache[key] = resolved
        fontCacheLock.unlock()
        return resolved
    }

    static func wrapInBoxedFrame(_ inner: MathLayoutBox, tag: String? = nil) -> MathLayoutBox {
        let padX: CGFloat = 5.5
        let padY: CGFloat = 3.5
        let boxWidth = inner.width + padX * 2.0
        let boxAscent = inner.ascent + padY
        let boxDescent = inner.descent + padY
        return MathLayoutBox(
            width: boxWidth,
            ascent: boxAscent,
            descent: boxDescent,
            tag: tag ?? inner.tag,
            usesNativeOpenTypeMath: inner.usesNativeOpenTypeMath
        ) { originX, baselineY, color in
            inner.drawBox(originX + padX, baselineY, color)
            let isFlipped = NSGraphicsContext.current?.isFlipped ?? true
            let rectY = isFlipped ? (baselineY - boxAscent + 0.5) : (baselineY - boxDescent + 0.5)
            let rect = NSRect(x: originX + 0.5, y: rectY, width: max(2.0, boxWidth - 1.0), height: max(2.0, boxAscent + boxDescent - 1.0))
            let path = NSBezierPath(roundedRect: rect, xRadius: 2.0, yRadius: 2.0)
            path.lineWidth = 1.15
            color.withAlphaComponent(max(0.4, color.alphaComponent * 0.88)).setStroke()
            path.stroke()
        }
    }
}

extension HybridMarkdownTextView {
    func drawRenderedMathBlock(
        mathBox: MathLayoutBox,
        blockRect: NSRect,
        origin: NSPoint,
        contentWidth: CGFloat,
        effectiveFontSize: CGFloat,
        mathColor: NSColor,
        dimFactor: CGFloat
    ) {
        let tagAttrs: [NSAttributedString.Key: Any] = [
            .font: currentTheme.bodyFont(size: effectiveFontSize * 0.92),
            .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(0.85 * dimFactor)
        ]
        var tagSize: NSSize = .zero
        if let tag = mathBox.tag, !tag.isEmpty {
            tagSize = (tag as NSString).size(withAttributes: tagAttrs)
        }
        let horizontalPad: CGFloat = 14.0
        let tagReserve: CGFloat = tagSize.width > 0 ? (tagSize.width + 18.0) : 0.0
        let availableMathWidth = max(80.0, contentWidth - horizontalPad * 2.0 - tagReserve)
        let scale: CGFloat = mathBox.width > availableMathWidth
            ? (availableMathWidth / max(1.0, mathBox.width))
            : 1.0
        let scaledWidth = mathBox.width * scale
        let centeredOffsetX = (contentWidth - scaledWidth) * 0.5
        let maxOffsetX = horizontalPad + availableMathWidth - scaledWidth
        let startX = origin.x + max(horizontalPad, min(centeredOffsetX, maxOffsetX))
        let baselineY = blockRect.midY + (mathBox.ascent - mathBox.descent) * 0.5 * scale

        if scale < 0.999, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: startX, y: baselineY)
            ctx.scaleBy(x: scale, y: scale)
            mathBox.drawBox(0.0, 0.0, mathColor)
            ctx.restoreGState()
        } else {
            mathBox.drawBox(startX, baselineY, mathColor)
        }

        if let tag = mathBox.tag, !tag.isEmpty {
            (tag as NSString).draw(
                at: NSPoint(
                    x: origin.x + contentWidth - tagSize.width - horizontalPad,
                    y: blockRect.midY - tagSize.height * 0.5
                ),
                withAttributes: tagAttrs
            )
        }
    }
}
