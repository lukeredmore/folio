import Foundation

/// TeX parameter text of a `\def` that has literal delimiters, such as `\def\IT#1 #2 {...}`.
/// `leading` must appear right after the macro name. `delimiters[n]` ends argument `n + 1`; an
/// empty delimiter means that argument is undelimited.
/// Where one macro argument is in the source characters, and its text.
struct LaTeXArgumentSpan: Equatable, Sendable {
    /// The argument with its braces or brackets. Nil for a default optional argument.
    let raw: Range<Int>?
    /// The argument without its braces. Nil for a default optional argument.
    let content: Range<Int>?
    let value: String
}

public struct LaTeXParameterText: Equatable, Hashable, Sendable {
    public let leading: String
    public let delimiters: [String]

    public init(leading: String, delimiters: [String]) {
        self.leading = leading
        self.delimiters = delimiters
    }
}

extension LaTeXMacroExpander {
    /// Parses the parameter text of `\def\name` from `start` up to the body's `{`. Returns
    /// `(argCount, parameterText, indexOfBrace)`. `parameterText` is nil when every parameter is
    /// undelimited, as in `#1#2{`. Returns nil for forms this parser does not support: `##`,
    /// parameters out of order, a `#` before the body brace, or a `}` before the body.
    static func parseDefParameterText(
        _ chars: [Character],
        from start: Int
    ) -> (argCount: Int, parameterText: LaTeXParameterText?, bodyStart: Int)? {
        var idx = start
        var leading = ""
        var delimiters: [String] = []
        while idx < chars.count && chars[idx] != "{" {
            let ch = chars[idx]
            if ch == "}" || ch == "%" { return nil }
            if ch == "#" {
                guard idx + 1 < chars.count, let digit = chars[idx + 1].wholeNumberValue,
                    digit == delimiters.count + 1, digit <= 9
                else { return nil }
                delimiters.append("")
                idx += 2
                continue
            }
            if ch == "\\" {
                let (word, after) = readControlWord(chars, at: idx)
                guard word.count > 1 else { return nil }
                appendDelimiterText(word, leading: &leading, delimiters: &delimiters)
                idx = after
                continue
            }
            appendDelimiterText(ch.isWhitespace ? " " : String(ch), leading: &leading, delimiters: &delimiters)
            idx += 1
        }
        guard idx < chars.count else { return nil }
        let hasDelimiters = !leading.trimmingCharacters(in: .whitespaces).isEmpty || delimiters.contains { !$0.isEmpty }
        let text = hasDelimiters ? LaTeXParameterText(leading: leading, delimiters: delimiters) : nil
        return (delimiters.count, text, idx)
    }

    /// Parses `{name}[argCount][default]{begin}{end}` after `\newenvironment`. The definition is
    /// stored under `LaTeXMacroDefinition.environmentKey(name)`.
    static func parseEnvironmentDefinition(
        _ chars: [Character],
        after start: Int
    ) -> (LaTeXMacroDefinition, Int)? {
        var idx = skipSpaces(chars, from: start)
        if idx < chars.count && chars[idx] == "*" { idx = skipSpaces(chars, from: idx + 1) }
        guard let (rawName, afterName) = readBracedGroup(chars, at: idx) else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\\") else { return nil }
        idx = skipBlank(chars, from: afterName)
        var argCount = 0
        if let (countText, afterCount) = readBracketGroup(chars, at: idx) {
            guard let parsed = Int(countText.trimmingCharacters(in: .whitespaces)), (0...9).contains(parsed) else { return nil }
            argCount = parsed
            idx = skipBlank(chars, from: afterCount)
        }
        var defaultFirstArg: String?
        if let (optDefault, afterOpt) = readBracketGroup(chars, at: idx) {
            defaultFirstArg = optDefault
            idx = skipBlank(chars, from: afterOpt)
        }
        guard let (beginCode, afterBegin) = readBracedGroup(chars, at: idx),
            let (endCode, afterEnd) = readBracedGroup(chars, at: skipBlank(chars, from: afterBegin))
        else { return nil }
        let definition = LaTeXMacroDefinition(
            name: LaTeXMacroDefinition.environmentKey(name),
            argCount: argCount,
            defaultFirstArg: defaultFirstArg,
            replacement: beginCode,
            isEnvironment: true,
            environmentEnd: endCode
        )
        return (definition, afterEnd)
    }

    /// Parses `fontspec` declarations: `\newfontfamily\cmd[opts]{Font}[opts]` and `\newfontface`.
    static func parseFontspecDefinition(
        cmd: String,
        _ chars: [Character],
        after start: Int
    ) -> (LaTeXMacroDefinition, Int)? {
        var idx = skipBlank(chars, from: start)
        guard let (rawName, afterName) = readMacroNameArg(chars, at: idx) else { return nil }
        idx = skipBlank(chars, from: afterName)
        var leadingOpt: String?
        if let (opt, afterOpt) = readBracketGroup(chars, at: idx) {
            leadingOpt = opt
            idx = skipBlank(chars, from: afterOpt)
        }
        guard let (rawFamily, afterFamily) = readBracedGroup(chars, at: idx) else { return nil }
        idx = skipSpaces(chars, from: afterFamily)
        var trailingOpt: String?
        if let (opt, afterOpt) = readBracketGroup(chars, at: idx) {
            trailingOpt = opt
            idx = afterOpt
        }
        let family = rawFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = [leadingOpt, trailingOpt].compactMap { $0 }.joined(separator: ",")
        let declaration = parseFontspecDeclaration(
            family: family,
            options: options,
            isFontFace: cmd.hasSuffix("fontface")
        )
        return (
            LaTeXMacroDefinition(
                name: rawName,
                argCount: 0,
                replacement: "",
                fontDeclaration: declaration
            ),
            idx
        )
    }

    /// Parses `\let\endfoo=\endlist` or `\let\endfoo\endbar` into `"foo"`, returning the index
    /// after the target token.
    static func parseEndEnvironmentAlias(_ chars: [Character], at start: Int) -> (String, Int)? {
        let (cmd, afterCmd) = readControlWord(chars, at: start)
        guard cmd == "\\let" else { return nil }
        var idx = skipSpaces(chars, from: afterCmd)
        guard let (rawName, afterName) = readMacroNameArg(chars, at: idx),
            rawName.hasPrefix("\\end")
        else { return nil }
        let envName = String(rawName.dropFirst(4))
        guard !envName.isEmpty else { return nil }
        idx = skipSpaces(chars, from: afterName)
        if idx < chars.count && chars[idx] == "=" {
            idx = skipSpaces(chars, from: idx + 1)
        }
        guard idx < chars.count else { return nil }
        let afterTarget = chars[idx] == "\\" ? readControlWord(chars, at: idx).1 : idx + 1
        return (envName, afterTarget)
    }

    private static func parseFontspecDeclaration(
        family: String,
        options: String,
        isFontFace: Bool
    ) -> LaTeXFontDeclaration {
        var decl = LaTeXFontDeclaration(fontFamily: family.isEmpty ? nil : family)
        for pair in splitCommaRespectingBraces(options) {
            guard let eqIdx = pair.firstIndex(of: "=") else { continue }
            let rawKey = String(pair[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(pair[pair.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = stripOuterBraces(rawKey).lowercased()
            let value = stripOuterBraces(rawValue)
            let lowerValue = value.lowercased()

            switch key {
            case "scale":
                if let scale = Double(value), scale >= 0.4, scale <= 4.0 {
                    decl.sizeScale = CGFloat(scale)
                }
            case "uprightfont", "font":
                if containsAnyWord(lowerValue, ["bold", "semibold", "demibold", "heavy", "black"]) {
                    decl.bold = true
                } else if containsAnyWord(lowerValue, ["light", "thin", "regular", "roman", "book"]) {
                    decl.bold = false
                }
                if containsAnyWord(lowerValue, ["italic", "oblique"]) {
                    decl.italic = true
                }
            case "series", "fontseries":
                if ["b", "bx", "sb", "bold", "semibold"].contains(lowerValue) {
                    decl.bold = true
                } else if ["m", "l", "regular", "light"].contains(lowerValue) {
                    decl.bold = false
                }
            case "shape", "fontshape":
                if ["it", "sl", "italic", "slanted"].contains(lowerValue) {
                    decl.italic = true
                } else if ["n", "up", "upright"].contains(lowerValue) {
                    decl.italic = false
                } else if ["sc", "smallcaps"].contains(lowerValue) {
                    decl.smallCaps = true
                }
            case "letters":
                if lowerValue.contains("smallcaps") {
                    decl.smallCaps = true
                }
            case "letterspace":
                if let ls = Double(value) {
                    decl.letterSpaceEm = min(0.5, max(-0.2, CGFloat(ls) / 100.0))
                }
            default:
                break
            }
        }
        if isFontFace {
            let lowerFamily = family.lowercased()
            if decl.bold == nil && containsAnyWord(lowerFamily, ["bold", "semibold", "demibold", "heavy", "black"]) {
                decl.bold = true
            }
            if decl.italic == nil && containsAnyWord(lowerFamily, ["italic", "oblique"]) {
                decl.italic = true
            }
        }
        return decl
    }

    private static func splitCommaRespectingBraces(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts: [String] = []
        var current = ""
        var depth = 0
        for ch in text {
            if ch == "{" {
                depth += 1
            } else if ch == "}" && depth > 0 {
                depth -= 1
            } else if ch == "," && depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    private static func stripOuterBraces(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), trimmed.count >= 2 else { return trimmed }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsAnyWord(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.contains($0) }
    }

    /// Skips spaces and `%` comments, which macro files put between definition parts.
    private static func skipBlank(_ chars: [Character], from start: Int) -> Int {
        var idx = skipSpaces(chars, from: start)
        while idx < chars.count && chars[idx] == "%" {
            while idx < chars.count && chars[idx] != "\n" { idx += 1 }
            idx = skipSpaces(chars, from: idx)
        }
        return idx
    }

    /// Adds delimiter text, collapsing a run of spaces into one, as TeX does when it reads tokens.
    private static func appendDelimiterText(_ piece: String, leading: inout String, delimiters: inout [String]) {
        if delimiters.isEmpty {
            if piece == " " && (leading.isEmpty || leading.hasSuffix(" ")) { return }
            leading += piece
        } else {
            let last = delimiters.count - 1
            if piece == " " && delimiters[last].hasSuffix(" ") { return }
            delimiters[last] += piece
        }
    }

    /// Reads the arguments that `def` takes, starting right after the macro name. Returns the
    /// argument texts and the index after the last one, or nil when the source does not supply
    /// them. Undelimited arguments skip spaces and take one token or braced group, without its
    /// braces. A delimited argument takes the text up to its delimiter at brace depth zero; when
    /// that text is one braced group, the braces are removed. The end of `chars` counts as a
    /// space, because TeX reads a line end as a space.
    static func readArguments(
        for def: LaTeXMacroDefinition,
        in chars: [Character],
        from start: Int
    ) -> (args: [String], end: Int)? {
        guard let (spans, end) = readArgumentSpans(for: def, in: chars, from: start) else { return nil }
        return (spans.map(\.value), end)
    }

    /// Reads the arguments as `readArguments` does and also returns where each one is in `chars`.
    static func readArgumentSpans(
        for def: LaTeXMacroDefinition,
        in chars: [Character],
        from start: Int
    ) -> (spans: [LaTeXArgumentSpan], end: Int)? {
        if let parameterText = def.parameterText {
            return readDelimitedArguments(parameterText, in: chars, from: start)
        }
        var idx = start
        var spans: [LaTeXArgumentSpan] = []
        if let defaultOpt = def.defaultFirstArg, def.argCount > 0 {
            let probe = skipSpaces(chars, from: idx)
            if let (optVal, afterOpt) = readBracketGroup(chars, at: probe) {
                spans.append(LaTeXArgumentSpan(raw: probe..<afterOpt, content: (probe + 1)..<(afterOpt - 1), value: optVal))
                idx = afterOpt
            } else {
                spans.append(LaTeXArgumentSpan(raw: nil, content: nil, value: defaultOpt))
            }
        }
        while spans.count < def.argCount {
            guard let span = readUndelimitedArgument(chars, at: skipSpaces(chars, from: idx)) else { return nil }
            spans.append(span)
            idx = span.raw?.upperBound ?? idx
        }
        return (spans, idx)
    }

    private static func readUndelimitedArgument(_ chars: [Character], at idx: Int) -> LaTeXArgumentSpan? {
        guard idx < chars.count, chars[idx] != "}", let (value, after) = readMacroArgument(chars, at: idx) else { return nil }
        let content = chars[idx] == "{" ? (idx + 1)..<(after - 1) : idx..<after
        return LaTeXArgumentSpan(raw: idx..<after, content: content, value: value)
    }

    private static func readDelimitedArguments(
        _ parameterText: LaTeXParameterText,
        in chars: [Character],
        from start: Int
    ) -> (spans: [LaTeXArgumentSpan], end: Int)? {
        // TeX skips spaces after a control word, so the parameter text starts at the next token.
        var idx = skipSpaces(chars, from: start)
        let leading = parameterText.leading.trimmingCharacters(in: .whitespaces)
        if !leading.isEmpty {
            guard let after = matchDelimiter(leading, in: chars, at: idx) else { return nil }
            idx = after
        }
        var spans: [LaTeXArgumentSpan] = []
        for delimiter in parameterText.delimiters {
            if delimiter.isEmpty {
                guard let span = readUndelimitedArgument(chars, at: skipSpaces(chars, from: idx)) else { return nil }
                spans.append(span)
                idx = span.raw?.upperBound ?? idx
                continue
            }
            guard let (span, after) = readUntilDelimiter(delimiter, in: chars, from: idx) else { return nil }
            spans.append(span)
            idx = after
        }
        return (spans, idx)
    }

    private static func readUntilDelimiter(
        _ delimiter: String,
        in chars: [Character],
        from start: Int
    ) -> (LaTeXArgumentSpan, Int)? {
        var depth = 0
        var idx = start
        while idx <= chars.count {
            if depth == 0, let after = matchDelimiter(delimiter, in: chars, at: idx) {
                let content = singleGroupContent(chars, in: start..<idx)
                return (LaTeXArgumentSpan(raw: start..<idx, content: content, value: String(chars[content])), after)
            }
            guard idx < chars.count else { return nil }
            switch chars[idx] {
            case "\\":
                idx += 2
                continue
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return nil }
            default:
                break
            }
            idx += 1
        }
        return nil
    }

    /// Matches `delimiter` at `idx`. A space matches one or more whitespace characters, or the
    /// end of `chars`. A control word must not be followed by a letter.
    private static func matchDelimiter(_ delimiter: String, in chars: [Character], at start: Int) -> Int? {
        let pattern = Array(delimiter)
        var p = 0
        var idx = start
        while p < pattern.count {
            if pattern[p] == " " {
                if idx == chars.count {
                    p += 1
                    continue
                }
                guard chars[idx].isWhitespace else { return nil }
                while idx < chars.count && chars[idx].isWhitespace { idx += 1 }
                p += 1
                continue
            }
            guard idx < chars.count, chars[idx] == pattern[p] else { return nil }
            idx += 1
            p += 1
        }
        if endsWithControlWord(pattern), idx < chars.count, chars[idx].isLetter { return nil }
        return idx
    }

    private static func endsWithControlWord(_ pattern: [Character]) -> Bool {
        var idx = pattern.count - 1
        while idx >= 0 && pattern[idx].isLetter { idx -= 1 }
        return idx >= 0 && idx < pattern.count - 1 && pattern[idx] == "\\"
    }

    /// The inside of `range` when it is exactly one braced group, else `range`.
    private static func singleGroupContent(_ chars: [Character], in range: Range<Int>) -> Range<Int> {
        guard range.count >= 2, chars[range.lowerBound] == "{",
            let (_, after) = readBracedGroup(chars, at: range.lowerBound), after == range.upperBound
        else { return range }
        return (range.lowerBound + 1)..<(range.upperBound - 1)
    }
}
