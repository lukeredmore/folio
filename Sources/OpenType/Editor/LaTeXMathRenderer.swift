import AppKit
import Foundation

public enum MathFontStyle: Equatable {
    case italicVariable
    case romanUpright
    case boldUpright
    case calligraphic
    case blackboardBold
    case monospace
    case operatorSymbol
    case bigOperator
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
    public let drawBox: (_ x: CGFloat, _ baselineY: CGFloat, _ color: NSColor) -> Void

    public var totalHeight: CGFloat { ascent + descent }
}

public final class LaTeXMathRenderer {

    // MARK: - Symbol Tables
    private static let symbolMap: [String: String] = [
        // Lowercase Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Uppercase Greek
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Calculus & Physics
        "nabla": "∇", "partial": "∂", "infty": "∞", "hbar": "ℏ",
        "ell": "ℓ", "wp": "℘", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
        "forall": "∀", "exists": "∃", "nexists": "∄", "emptyset": "∅", "varnothing": "∅",
        "prime": "′", "dagger": "†", "ddagger": "‡", "angle": "∠", "triangle": "△",
        // Binary operators
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙",
        "circ": "∘", "bullet": "•", "star": "⋆", "ast": "∗",
        "cup": "∪", "cap": "∩", "setminus": "∖", "wedge": "∧", "vee": "∨",
        // Relations
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅",
        "propto": "∝", "ll": "≪", "gg": "≫", "subset": "⊂", "supset": "⊃",
        "subseteq": "⊆", "supseteq": "⊇", "in": "∈", "notin": "∉", "ni": "∋",
        "perp": "⊥", "parallel": "∥", "mid": "∣",
        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "leftrightarrow": "↔",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "iff": "⇔",
        "mapsto": "↦", "uparrow": "↑", "downarrow": "↓", "nearrow": "↗", "searrow": "↘",
        // Dots
        "dots": "…", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        // Brackets
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "{": "{", "}": "}"
    ]

    private static let bigOperators: [String: String] = [
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "sum": "∑", "prod": "∏", "coprod": "∐",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂"
    ]

    private static let namedFunctions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
        "log", "ln", "lg", "exp", "lim", "limsup", "liminf",
        "sup", "inf", "min", "max", "arg", "det", "dim", "ker", "hom", "deg", "gcd", "Pr"
    ]

    private static let calligraphicMap: [Character: String] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ", "G": "𝒢",
        "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ", "M": "ℳ", "N": "𝒩",
        "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ", "S": "𝒮", "T": "𝒯", "U": "𝒰",
        "V": "𝒱", "W": "𝒲", "X": "𝒳", "Y": "𝒴", "Z": "𝒵"
    ]

    private static let blackboardMap: [Character: String] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽", "G": "𝔾",
        "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃", "M": "𝕄", "N": "ℕ",
        "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "S": "𝕊", "T": "𝕋", "U": "𝕌",
        "V": "𝕍", "W": "𝕎", "X": "𝕏", "Y": "𝕐", "Z": "ℤ"
    ]

    // MARK: - Public API
    public static func parse(_ latex: String) -> MathNode {
        let chars = Array(latex.trimmingCharacters(in: .whitespacesAndNewlines))
        var index = 0
        return parseSequence(chars, index: &index, stopOnRightCommand: false)
    }

    public static func layout(
        node: MathNode,
        baseFontSize: CGFloat,
        isDisplayStyle: Bool
    ) -> MathLayoutBox {
        let effectiveSize = isDisplayStyle ? baseFontSize * 1.18 : baseFontSize * 1.02
        return layoutNode(node, fontSize: effectiveSize, isDisplay: isDisplayStyle)
    }

    /// Converts a LaTeX expression to a readable plain/Unicode representation (useful for accessibility & unit tests)
    public static func plainTextSummary(of latex: String) -> String {
        let node = parse(latex)
        return flattenToText(node)
    }

    private static func flattenToText(_ node: MathNode) -> String {
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

    // MARK: - Recursive Descent LaTeX Parser
    private static func parseSequence(
        _ chars: [Character],
        index: inout Int,
        stopOnRightCommand: Bool
    ) -> MathNode {
        var nodes: [MathNode] = []

        while index < chars.count {
            let ch = chars[index]

            if ch == "}" {
                break
            }

            if ch.isWhitespace {
                index += 1
                continue
            }

            // Check for \right delimiter termination
            if stopOnRightCommand, ch == "\\" {
                let remaining = String(chars[index...])
                if remaining.hasPrefix("\\right") {
                    break
                }
            }

            guard let atom = parseAtom(chars, index: &index) else {
                continue
            }

            // Check for trailing subscript (_) and/or superscript (^)
            var subNode: MathNode?
            var supNode: MathNode?

            while index < chars.count {
                while index < chars.count && chars[index].isWhitespace {
                    index += 1
                }
                guard index < chars.count else { break }
                if chars[index] == "_" {
                    index += 1
                    subNode = parseScriptArgument(chars, index: &index)
                } else if chars[index] == "^" {
                    index += 1
                    supNode = parseScriptArgument(chars, index: &index)
                } else if chars[index] == "'" {
                    index += 1
                    let primeNode = MathNode.text("′", .operatorSymbol)
                    if let existingSup = supNode {
                        supNode = .row([existingSup, primeNode])
                    } else {
                        supNode = primeNode
                    }
                } else {
                    break
                }
            }

            if subNode != nil || supNode != nil {
                nodes.append(.scripts(base: atom, sub: subNode, sup: supNode))
            } else {
                nodes.append(atom)
            }
        }

        if nodes.count == 1 {
            return nodes[0]
        }
        return .row(nodes)
    }

    private static func parseScriptArgument(_ chars: [Character], index: inout Int) -> MathNode {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else {
            return .text("", .italicVariable)
        }
        if chars[index] == "{" {
            return parseBracedGroup(chars, index: &index)
        }
        return parseAtom(chars, index: &index) ?? .text("", .italicVariable)
    }

    private static func parseBracedGroup(_ chars: [Character], index: inout Int) -> MathNode {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else {
            return .text("", .italicVariable)
        }
        if chars[index] == "{" {
            index += 1 // consume '{'
            let inside = parseSequence(chars, index: &index, stopOnRightCommand: false)
            if index < chars.count && chars[index] == "}" {
                index += 1 // consume '}'
            }
            return inside
        } else {
            return parseAtom(chars, index: &index) ?? .text("", .italicVariable)
        }
    }

    private static func extractRawBracedString(_ chars: [Character], index: inout Int) -> String {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else { return "" }
        if chars[index] == "{" {
            index += 1
            var depth = 1
            var out = ""
            while index < chars.count && depth > 0 {
                let c = chars[index]
                index += 1
                if c == "{" {
                    depth += 1
                    if depth > 1 { out.append(c) }
                } else if c == "}" {
                    depth -= 1
                    if depth > 0 { out.append(c) }
                } else {
                    out.append(c)
                }
            }
            return out
        } else {
            let c = chars[index]
            index += 1
            return String(c)
        }
    }

    private static func parseAtom(_ chars: [Character], index: inout Int) -> MathNode? {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else { return nil }

        let ch = chars[index]

        if ch == "{" {
            return parseBracedGroup(chars, index: &index)
        }

        if ch == "\\" {
            index += 1
            guard index < chars.count else { return nil }

            let first = chars[index]
            // Single-character spacing or escaped symbols
            if !first.isLetter {
                index += 1
                switch first {
                case ",": return .space(3.0)
                case ";", ":": return .space(4.5)
                case "!": return .space(-1.5)
                case " ": return .space(4.0)
                case "{", "}", "%", "$", "&", "#":
                    return .text(String(first), .romanUpright)
                default:
                    return .text(String(first), .operatorSymbol)
                }
            }

            // Read alphabetic command name
            var cmd = ""
            while index < chars.count && chars[index].isLetter {
                cmd.append(chars[index])
                index += 1
            }

            switch cmd {
            case "frac", "dfrac", "tfrac":
                let num = parseBracedGroup(chars, index: &index)
                let den = parseBracedGroup(chars, index: &index)
                return .fraction(numerator: num, denominator: den)

            case "sqrt":
                if index < chars.count && chars[index] == "[" {
                    while index < chars.count && chars[index] != "]" { index += 1 }
                    if index < chars.count { index += 1 }
                }
                let rad = parseBracedGroup(chars, index: &index)
                return .sqrt(radicand: rad)

            case "left":
                let leftDelim = readDelimiterToken(chars, index: &index)
                let body = parseSequence(chars, index: &index, stopOnRightCommand: true)
                var rightDelim = ")"
                if index < chars.count && chars[index] == "\\" {
                    let rem = String(chars[index...])
                    if rem.hasPrefix("\\right") {
                        index += 6 // consume \right
                        rightDelim = readDelimiterToken(chars, index: &index)
                    }
                }
                return .delimited(left: leftDelim, body: body, right: rightDelim)

            case "text", "textrm", "mathrm", "operatorname":
                let raw = extractRawBracedString(chars, index: &index)
                return .text(raw, .romanUpright)

            case "mathbf", "textbf", "boldsymbol", "bm":
                let raw = extractRawBracedString(chars, index: &index)
                // Also resolve any nested symbol like \mathbf{\nabla}
                let resolved = resolveSimpleSymbols(in: raw)
                return .text(resolved, .boldUpright)

            case "mathcal", "mathscr":
                let raw = extractRawBracedString(chars, index: &index)
                let mapped = String(raw.map { ch in
                    if let cal = calligraphicMap[ch] { return Character(cal) }
                    return ch
                })
                return .text(mapped, .calligraphic)

            case "mathbb":
                let raw = extractRawBracedString(chars, index: &index)
                let mapped = String(raw.map { ch in
                    if let bb = blackboardMap[ch] { return Character(bb) }
                    return ch
                })
                return .text(mapped, .blackboardBold)

            case "mathtt", "texttt":
                let raw = extractRawBracedString(chars, index: &index)
                return .text(raw, .monospace)

            case "mathit", "textit":
                let raw = extractRawBracedString(chars, index: &index)
                return .text(raw, .italicVariable)

            case "hat", "widehat":
                return .accent(base: parseBracedGroup(chars, index: &index), mark: "̂")
            case "bar", "overline":
                return .accent(base: parseBracedGroup(chars, index: &index), mark: "̄")
            case "vec", "overrightarrow":
                return .accent(base: parseBracedGroup(chars, index: &index), mark: "⃗")
            case "tilde", "widetilde":
                return .accent(base: parseBracedGroup(chars, index: &index), mark: "̃")
            case "dot":
                return .accent(base: parseBracedGroup(chars, index: &index), mark: "̇")
            case "ddot":
                return .accent(base: parseBracedGroup(chars, index: &index), mark: "̈")

            case "quad":
                return .space(12.0)
            case "qquad":
                return .space(22.0)

            default:
                if let bigOp = bigOperators[cmd] {
                    return .text(bigOp, .bigOperator)
                }
                if namedFunctions.contains(cmd) {
                    return .text(cmd, .romanUpright)
                }
                if let sym = symbolMap[cmd] {
                    let isGreekLetter = cmd.first?.isLetter == true && [
                        "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta",
                        "theta", "vartheta", "iota", "kappa", "lambda", "mu", "nu", "xi", "pi",
                        "rho", "sigma", "varsigma", "tau", "upsilon", "phi", "varphi", "chi", "psi", "omega"
                    ].contains(cmd)
                    return .text(sym, isGreekLetter ? .italicVariable : .operatorSymbol)
                }
                return .text(cmd, .romanUpright)
            }
        }

        // Numbers
        if ch.isNumber {
            var numStr = ""
            while index < chars.count && (chars[index].isNumber || chars[index] == ".") {
                numStr.append(chars[index])
                index += 1
            }
            return .text(numStr, .romanUpright)
        }

        // Standard operators with breathable spacing
        if "+-=<>".contains(ch) {
            index += 1
            let opSymbol = ch == "-" ? "−" : String(ch)
            return .row([.space(2.5), .text(opSymbol, .operatorSymbol), .space(2.5)])
        }

        if "*/(),:;[]|!".contains(ch) {
            index += 1
            if ch == "*" {
                return .text("∗", .operatorSymbol)
            }
            return .text(String(ch), .romanUpright)
        }

        // Single variable letter
        index += 1
        return .text(String(ch), .italicVariable)
    }

    private static func readDelimiterToken(_ chars: [Character], index: inout Int) -> String {
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else { return "" }
        if chars[index] == "\\" {
            index += 1
            guard index < chars.count else { return "" }
            if !chars[index].isLetter {
                let c = chars[index]
                index += 1
                return String(c)
            }
            var cmd = ""
            while index < chars.count && chars[index].isLetter {
                cmd.append(chars[index])
                index += 1
            }
            return symbolMap[cmd] ?? cmd
        } else {
            let c = chars[index]
            index += 1
            return c == "." ? "" : String(c)
        }
    }

    private static func resolveSimpleSymbols(in raw: String) -> String {
        var result = raw
        for (k, v) in symbolMap {
            result = result.replacingOccurrences(of: "\\\(k)", with: v)
        }
        return result
    }

    // MARK: - 2D Box Layout Engine (Flipped NSView coordinates: +y is downward)
    private static func font(for style: MathFontStyle, size: CGFloat) -> NSFont {
        switch style {
        case .italicVariable:
            return NSFont(name: "Times New Roman Italic", size: size)
                ?? NSFont(name: "Georgia Italic", size: size)
                ?? NSFontManager.shared.convert(NSFont.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
        case .romanUpright, .calligraphic, .blackboardBold:
            return NSFont(name: "Times New Roman", size: size)
                ?? NSFont(name: "Georgia", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .boldUpright:
            return NSFont(name: "Times New Roman Bold", size: size)
                ?? NSFont(name: "Georgia Bold", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .bold)
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
        case .operatorSymbol:
            return NSFont(name: "Times New Roman", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .bigOperator:
            return NSFont(name: "Times New Roman", size: size * 1.45)
                ?? NSFont.systemFont(ofSize: size * 1.45, weight: .light)
        }
    }

    private static func layoutNode(
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

    private static func drawTallDelimiter(
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
