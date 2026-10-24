import AppKit
import Foundation
import FolioEngineFFI

public enum MathFontStyle: Equatable {
    case italicVariable
    case romanUpright
    case boldUpright
    case calligraphic
    case blackboardBold
    case monospace
    case operatorSymbol
    case bigOperator

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

public indirect enum MathNode: Equatable {
    case row([MathNode])
    case text(String, MathFontStyle)
    case space(CGFloat)
    case fraction(numerator: MathNode, denominator: MathNode)
    case sqrt(radicand: MathNode)
    case scripts(base: MathNode, sub: MathNode?, sup: MathNode?)
    case delimited(left: String, body: MathNode, right: String)
    case accent(base: MathNode, mark: String)
}

public struct MathLayoutBox {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let tag: String?
    public let usesNativeOpenTypeMath: Bool
    public let drawBox: (_ x: CGFloat, _ baselineY: CGFloat, _ color: NSColor) -> Void

    public init(
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        tag: String? = nil,
        usesNativeOpenTypeMath: Bool = false,
        drawBox: @escaping (_ x: CGFloat, _ baselineY: CGFloat, _ color: NSColor) -> Void
    ) {
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.tag = tag
        self.usesNativeOpenTypeMath = usesNativeOpenTypeMath
        self.drawBox = drawBox
    }

    public var totalHeight: CGFloat { ascent + descent }
}

enum CapturedEngineDrawCmd {
    case text(x: CGFloat, y: CGFloat, text: String, style: MathFontStyle, fontSize: CGFloat)
    case rule(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
    case radical(x: CGFloat, topY: CGFloat, bottomY: CGFloat, hookWidth: CGFloat, radicandWidth: CGFloat, thickness: CGFloat)
    case delimiter(symbol: String, x: CGFloat, topY: CGFloat, bottomY: CGFloat, width: CGFloat, thickness: CGFloat)
}

public final class LaTeXMathRenderer {

    // MARK: - Public API
    public static func parse(_ latex: String) -> MathNode {
        let chars = Array(latex.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0
        return parseSequence(chars, index: &index, stopOnRightCommand: false, stopOnCloseBrace: false, depth: 0)
    }

    /// Executes 2D math parsing and OpenType MATH layout via SwiftMath, falling back to the Rust/Swift engine if incomplete.
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
            return layout(node: parse(latex), baseFontSize: baseFontSize, isDisplayStyle: isDisplayStyle)
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
                        x: CGFloat(cmd.x),
                        y: CGFloat(cmd.y),
                        text: str,
                        style: MathFontStyle.fromEngineCode(cmd.font_style),
                        fontSize: CGFloat(cmd.font_size)
                    ))
                case 1:
                    captured.append(.rule(
                        x: CGFloat(cmd.x),
                        y: CGFloat(cmd.y),
                        width: CGFloat(cmd.width),
                        height: CGFloat(cmd.height)
                    ))
                case 2:
                    captured.append(.radical(
                        x: CGFloat(cmd.x),
                        topY: CGFloat(cmd.y),
                        bottomY: CGFloat(cmd.height),
                        hookWidth: CGFloat(cmd.width),
                        radicandWidth: CGFloat(cmd.font_size),
                        thickness: CGFloat(cmd.thickness)
                    ))
                case 3:
                    let sym = cmd.text != nil ? String(cString: cmd.text) : "|"
                    captured.append(.delimiter(
                        symbol: sym,
                        x: CGFloat(cmd.x),
                        topY: CGFloat(cmd.y),
                        bottomY: CGFloat(cmd.height),
                        width: CGFloat(cmd.width),
                        thickness: CGFloat(cmd.thickness)
                    ))
                default:
                    break
                }
            }
        }

        return MathLayoutBox(
            width: CGFloat(res.width),
            ascent: CGFloat(res.ascent),
            descent: CGFloat(res.descent),
            tag: tag,
            usesNativeOpenTypeMath: false
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
                case let .radical(dx, topYRel, bottomYRel, hookWidth, radicandWidth, thickness):
                    let x = originX + dx
                    let topY = baselineY + topYRel
                    let bottomY = baselineY + bottomYRel
                    let path = NSBezierPath()
                    path.lineWidth = thickness
                    path.lineCapStyle = .round
                    path.lineJoinStyle = .round
                    path.move(to: NSPoint(x: x + 1.0, y: topY + (bottomY - topY) * 0.55))
                    path.line(to: NSPoint(x: x + hookWidth * 0.42, y: bottomY))
                    path.line(to: NSPoint(x: x + hookWidth, y: topY))
                    path.line(to: NSPoint(x: x + hookWidth + radicandWidth + 2.0, y: topY))
                    color.setStroke()
                    path.stroke()
                case let .delimiter(symbol, dx, topYRel, bottomYRel, width, _):
                    drawTallDelimiter(
                        symbol,
                        x: originX + dx,
                        topY: baselineY + topYRel,
                        bottomY: baselineY + bottomYRel,
                        width: width,
                        color: color
                    )
                }
            }
        }
    }

    public static func layout(
        node: MathNode,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool
    ) -> MathLayoutBox {
        let effectiveSize = isDisplayStyle ? baseFontSize * 1.18 : baseFontSize * 1.02
        return layoutNode(node, fontSize: effectiveSize, isDisplay: isDisplayStyle)
    }

    /// Converts a LaTeX expression to a readable plain/Unicode representation via the Rust core engine
    public static func plainTextSummary(of latex: String) -> String {
        let cOut = latex.withCString { cStr in
            ot_engine_plain_text_latex(cStr)
        }
        guard let ptr = cOut else {
            return flattenToText(parse(latex))
        }
        defer { ot_engine_free_string(ptr) }
        return String(cString: ptr)
    }

    static func flattenToText(_ node: MathNode) -> String {
        switch node {
        case .row(let children):
            return children.map(flattenToText).joined()
        case .text(let s, _):
            return s
        case .space:
            return " "
        case .fraction(let num, let den):
            return "(\(flattenToText(num)))/(\(flattenToText(den)))"
        case .sqrt(let rad):
            return "√(\(flattenToText(rad)))"
        case .scripts(let base, let sub, let sup):
            var res = flattenToText(base)
            if let sub = sub { res += "_\(flattenToText(sub))" }
            if let sup = sup { res += "^\(flattenToText(sup))" }
            return res
        case .delimited(let l, let body, let r):
            return "\(l)\(flattenToText(body))\(r)"
        case .accent(let base, let mark):
            return "\(flattenToText(base))\(mark)"
        }
    }
}
