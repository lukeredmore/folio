import AppKit
import Foundation

extension LaTeXMathRenderer {

    // MARK: - Recursive Descent LaTeX Parser
    static func parseSequence(
        _ chars: [Character],
        index: inout Int,
        stopOnRightCommand: Bool,
        stopOnCloseBrace: Bool,
        depth: Int
    ) -> MathNode {
        if depth > maxParseDepth {
            if index < chars.count { index += 1 }
            return .text("", .romanUpright)
        }

        var nodes: [MathNode] = []

        while index < chars.count {
            let ch = chars[index]

            if ch == "}" {
                if stopOnCloseBrace {
                    break
                } else {
                    index += 1
                    nodes.append(.text("}", .romanUpright))
                    continue
                }
            }

            if ch.isWhitespace {
                index += 1
                continue
            }

            // Check for \right delimiter termination in O(1) without String slice allocation
            if stopOnRightCommand, ch == "\\", isRightDelimiterCommand(chars, at: index) {
                break
            }

            guard let atom = parseAtom(chars, index: &index, depth: depth + 1) else {
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
                    subNode = parseScriptArgument(chars, index: &index, depth: depth + 1)
                } else if chars[index] == "^" {
                    index += 1
                    supNode = parseScriptArgument(chars, index: &index, depth: depth + 1)
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

    static func parseScriptArgument(_ chars: [Character], index: inout Int, depth: Int) -> MathNode {
        if depth > maxParseDepth {
            if index < chars.count { index += 1 }
            return .text("", .italicVariable)
        }
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else {
            return .text("", .italicVariable)
        }
        if chars[index] == "{" {
            return parseBracedGroup(chars, index: &index, depth: depth + 1)
        }
        return parseAtom(chars, index: &index, depth: depth + 1) ?? .text("", .italicVariable)
    }

    static func parseBracedGroup(_ chars: [Character], index: inout Int, depth: Int) -> MathNode {
        if depth > maxParseDepth {
            if index < chars.count { index += 1 }
            return .text("", .italicVariable)
        }
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else {
            return .text("", .italicVariable)
        }
        if chars[index] == "{" {
            index += 1 // consume '{'
            let inside = parseSequence(chars, index: &index, stopOnRightCommand: false, stopOnCloseBrace: true, depth: depth + 1)
            if index < chars.count && chars[index] == "}" {
                index += 1 // consume '}'
            }
            return inside
        } else {
            return parseAtom(chars, index: &index, depth: depth + 1) ?? .text("", .italicVariable)
        }
    }

    static func parseAtom(_ chars: [Character], index: inout Int, depth: Int) -> MathNode? {
        if depth > maxParseDepth {
            if index < chars.count { index += 1 }
            return nil
        }
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        guard index < chars.count else { return nil }

        let ch = chars[index]

        if ch == "{" {
            return parseBracedGroup(chars, index: &index, depth: depth + 1)
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
                let num = parseBracedGroup(chars, index: &index, depth: depth + 1)
                let den = parseBracedGroup(chars, index: &index, depth: depth + 1)
                return .fraction(numerator: num, denominator: den)

            case "sqrt":
                if index < chars.count && chars[index] == "[" {
                    while index < chars.count && chars[index] != "]" { index += 1 }
                    if index < chars.count { index += 1 }
                }
                let rad = parseBracedGroup(chars, index: &index, depth: depth + 1)
                return .sqrt(radicand: rad)

            case "left":
                let leftDelim = readDelimiterToken(chars, index: &index)
                let body = parseSequence(chars, index: &index, stopOnRightCommand: true, stopOnCloseBrace: stopOnCloseBraceForLeft(), depth: depth + 1)
                var rightDelim = ")"
                if index < chars.count && chars[index] == "\\" && isRightDelimiterCommand(chars, at: index) {
                    index += 6 // consume \right
                    rightDelim = readDelimiterToken(chars, index: &index)
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
                return .accent(base: parseBracedGroup(chars, index: &index, depth: depth + 1), mark: "̂")
            case "bar", "overline":
                return .accent(base: parseBracedGroup(chars, index: &index, depth: depth + 1), mark: "̄")
            case "vec", "overrightarrow":
                return .accent(base: parseBracedGroup(chars, index: &index, depth: depth + 1), mark: "⃗")
            case "tilde", "widetilde":
                return .accent(base: parseBracedGroup(chars, index: &index, depth: depth + 1), mark: "̃")
            case "dot":
                return .accent(base: parseBracedGroup(chars, index: &index, depth: depth + 1), mark: "̇")
            case "ddot":
                return .accent(base: parseBracedGroup(chars, index: &index, depth: depth + 1), mark: "̈")

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
}
