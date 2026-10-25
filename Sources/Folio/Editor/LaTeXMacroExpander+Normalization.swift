import Foundation

extension LaTeXMacroExpander {
    static func expandMacrosOnce(
        in text: String,
        macros: [String: LaTeXMacroDefinition]
    ) -> String {
        guard !macros.isEmpty else { return text }
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                let (cmd, afterCmd) = readControlWord(chars, at: i)
                if let def = macros[cmd], def.operatorText == nil {
                    var idx = afterCmd
                    var args: [String] = []
                    if let defaultOpt = def.defaultFirstArg, def.argCount > 0 {
                        let probe = skipSpaces(chars, from: idx)
                        if let (optVal, afterOpt) = readBracketGroup(chars, at: probe) {
                            args.append(optVal)
                            idx = afterOpt
                        } else {
                            args.append(defaultOpt)
                        }
                    }
                    var allFound = true
                    while args.count < def.argCount {
                        let probe = skipSpaces(chars, from: idx)
                        if let (argVal, afterArg) = readMacroArgument(chars, at: probe) {
                            args.append(argVal)
                            idx = afterArg
                        } else {
                            allFound = false
                            break
                        }
                    }
                    if allFound {
                        var expanded = def.replacement
                        for (argIdx, argVal) in args.enumerated() {
                            expanded = expanded.replacingOccurrences(of: "#\(argIdx + 1)", with: argVal)
                        }
                        out.append(expanded)
                        i = idx
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    static func extractTag(from text: String) -> (String, String?) {
        let chars = Array(text)
        var out = ""
        var extractedTag: String?
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                let (cmd, afterCmd) = readControlWord(chars, at: i)
                if cmd == "\\tag" {
                    var idx = skipSpaces(chars, from: afterCmd)
                    var isStarred = false
                    if idx < chars.count && chars[idx] == "*" {
                        isStarred = true
                        idx = skipSpaces(chars, from: idx + 1)
                    }
                    if let (tagBody, afterTag) = readBracedGroup(chars, at: idx) {
                        let clean = tagBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        extractedTag = isStarred ? clean : "(\(clean))"
                        i = afterTag
                        continue
                    }
                } else if cmd == "\\label" {
                    let idx = skipSpaces(chars, from: afterCmd)
                    if let (_, afterLabel) = readBracedGroup(chars, at: idx) {
                        i = afterLabel
                        continue
                    }
                } else if cmd == "\\nonumber" || cmd == "\\notag" {
                    i = afterCmd
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return (out, extractedTag)
    }

    static func normalizeEnvironmentsAndCommands(_ text: String) -> String {
        var result = text
        let envRewrites: [(String, String)] = [
            ("align*", "aligned"),
            ("align", "aligned"),
            ("flalign*", "aligned"),
            ("flalign", "aligned"),
            ("gather*", "gather"),
            ("gathered", "gather"),
            ("multline*", "gather"),
            ("multline", "gather"),
            ("smallmatrix", "matrix"),
        ]
        for (src, dst) in envRewrites {
            result = result.replacingOccurrences(of: "\\begin{\(src)}", with: "\\begin{\(dst)}")
            result = result.replacingOccurrences(of: "\\end{\(src)}", with: "\\end{\(dst)}")
        }
        for eqEnv in ["equation*", "equation", "displaymath", "math"] {
            result = result.replacingOccurrences(of: "\\begin{\(eqEnv)}", with: "")
            result = result.replacingOccurrences(of: "\\end{\(eqEnv)}", with: "")
        }

        let chars = Array(result)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\" {
                let (cmd, afterCmd) = readControlWord(chars, at: i)
                if cmd == "\\dfrac" || cmd == "\\cfrac" {
                    out.append("\\displaystyle\\frac")
                    i = afterCmd
                    continue
                } else if cmd == "\\tfrac" {
                    out.append("\\textstyle\\frac")
                    i = afterCmd
                    continue
                } else if cmd == "\\dbinom" {
                    out.append("\\displaystyle\\binom")
                    i = afterCmd
                    continue
                } else if cmd == "\\tbinom" {
                    out.append("\\textstyle\\binom")
                    i = afterCmd
                    continue
                } else if cmd == "\\boldsymbol" {
                    out.append("\\bm")
                    i = afterCmd
                    continue
                } else if cmd == "\\mathscr" {
                    out.append("\\mathcal")
                    i = afterCmd
                    continue
                } else if cmd == "\\lVert" || cmd == "\\rVert" {
                    out.append("\\Vert")
                    i = afterCmd
                    continue
                } else if cmd == "\\lvert" || cmd == "\\rvert" {
                    out.append("\\vert")
                    i = afterCmd
                    continue
                } else if cmd == "\\operatorname" {
                    var idx = skipSpaces(chars, from: afterCmd)
                    if idx < chars.count && chars[idx] == "*" { idx += 1 }
                    out.append("\\mathrm")
                    i = idx
                    continue
                } else if cmd == "\\substack" {
                    let idx = skipSpaces(chars, from: afterCmd)
                    if let (body, afterBody) = readBracedGroup(chars, at: idx) {
                        out.append("\\begin{matrix}\(body)\\end{matrix}")
                        i = afterBody
                        continue
                    }
                } else if cmd == "\\ket" {
                    let idx = skipSpaces(chars, from: afterCmd)
                    if let (body, afterBody) = readBracedGroup(chars, at: idx) {
                        out.append("\\left\\vert \(body) \\right\\rangle")
                        i = afterBody
                        continue
                    }
                } else if cmd == "\\bra" {
                    let idx = skipSpaces(chars, from: afterCmd)
                    if let (body, afterBody) = readBracedGroup(chars, at: idx) {
                        out.append("\\left\\langle \(body) \\right\\vert")
                        i = afterBody
                        continue
                    }
                } else if cmd == "\\braket" {
                    let idx1 = skipSpaces(chars, from: afterCmd)
                    if let (lhs, afterLhs) = readBracedGroup(chars, at: idx1) {
                        let idx2 = skipSpaces(chars, from: afterLhs)
                        if let (rhs, afterRhs) = readBracedGroup(chars, at: idx2) {
                            out.append("\\left\\langle \(lhs) \\vert \(rhs) \\right\\rangle")
                            i = afterRhs
                            continue
                        }
                    }
                } else if isDelimiterSizingCommand(cmd) {
                    i = afterCmd
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func isDelimiterSizingCommand(_ cmd: String) -> Bool {
        switch cmd {
        case "\\big", "\\Big", "\\bigg", "\\Bigg",
             "\\bigl", "\\bigr", "\\Bigl", "\\Bigr",
             "\\biggl", "\\biggr", "\\Biggl", "\\Biggr",
             "\\bigm", "\\Bigm", "\\biggm", "\\Biggm",
             "\\middle":
            return true
        default:
            return false
        }
    }

    static func skipSpaces(_ chars: [Character], from index: Int) -> Int {
        var idx = index
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "\t" || chars[idx] == "\n") {
            idx += 1
        }
        return idx
    }

    static func readControlWord(_ chars: [Character], at start: Int) -> (String, Int) {
        guard start < chars.count, chars[start] == "\\" else { return ("", start) }
        var idx = start + 1
        if idx < chars.count && (chars[idx].isLetter || chars[idx] == "@") {
            while idx < chars.count && (chars[idx].isLetter || chars[idx] == "@") {
                idx += 1
            }
        } else if idx < chars.count {
            idx += 1
        }
        return (String(chars[start..<idx]), idx)
    }

    static func readMacroNameArg(_ chars: [Character], at start: Int) -> (String, Int)? {
        if start < chars.count && chars[start] == "{" {
            guard let (inner, after) = readBracedGroup(chars, at: start) else { return nil }
            let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\\"), trimmed.count > 1 else { return nil }
            return (trimmed, after)
        } else if start < chars.count && chars[start] == "\\" {
            let (word, after) = readControlWord(chars, at: start)
            guard word.count > 1 else { return nil }
            return (word, after)
        }
        return nil
    }

    static func readBracedGroup(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "{" else { return nil }
        var depth = 0
        var idx = start
        while idx < chars.count {
            if chars[idx] == "\\" {
                idx += 2
                continue
            }
            if chars[idx] == "{" {
                depth += 1
            } else if chars[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(chars[(start + 1)..<idx]), idx + 1)
                }
            }
            idx += 1
        }
        return nil
    }

    static func readBracketGroup(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard start < chars.count, chars[start] == "[" else { return nil }
        var depth = 0
        var idx = start
        while idx < chars.count {
            if chars[idx] == "{" { depth += 1 }
            else if chars[idx] == "}" { depth = max(0, depth - 1) }
            else if chars[idx] == "]" && depth == 0 {
                return (String(chars[(start + 1)..<idx]), idx + 1)
            }
            idx += 1
        }
        return nil
    }

    static func readMacroArgument(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard start < chars.count else { return nil }
        if chars[start] == "{" {
            return readBracedGroup(chars, at: start)
        } else if chars[start] == "\\" {
            return readControlWord(chars, at: start)
        } else {
            return (String(chars[start]), start + 1)
        }
    }
}
