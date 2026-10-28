import Foundation

/// TeX parameter text of a `\def` that has literal delimiters, such as `\def\IT#1 #2 {...}`.
/// `leading` must appear right after the macro name. `delimiters[n]` ends argument `n + 1`; an
/// empty delimiter means that argument is undelimited.
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
    /// space, because the caller passes a single line and TeX reads a line end as a space.
    static func readArguments(
        for def: LaTeXMacroDefinition,
        in chars: [Character],
        from start: Int
    ) -> (args: [String], end: Int)? {
        if let parameterText = def.parameterText {
            return readDelimitedArguments(parameterText, in: chars, from: start)
        }
        var idx = start
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
        while args.count < def.argCount {
            guard let (value, after) = readUndelimitedArgument(chars, at: skipSpaces(chars, from: idx)) else { return nil }
            args.append(value)
            idx = after
        }
        return (args, idx)
    }

    private static func readUndelimitedArgument(_ chars: [Character], at idx: Int) -> (String, Int)? {
        guard idx < chars.count, chars[idx] != "}" else { return nil }
        return readMacroArgument(chars, at: idx)
    }

    private static func readDelimitedArguments(
        _ parameterText: LaTeXParameterText,
        in chars: [Character],
        from start: Int
    ) -> (args: [String], end: Int)? {
        // TeX skips spaces after a control word, so the parameter text starts at the next token.
        var idx = skipSpaces(chars, from: start)
        let leading = parameterText.leading.trimmingCharacters(in: .whitespaces)
        if !leading.isEmpty {
            guard let after = matchDelimiter(leading, in: chars, at: idx) else { return nil }
            idx = after
        }
        var args: [String] = []
        for delimiter in parameterText.delimiters {
            if delimiter.isEmpty {
                guard let (value, after) = readUndelimitedArgument(chars, at: skipSpaces(chars, from: idx)) else { return nil }
                args.append(value)
                idx = after
                continue
            }
            guard let (value, after) = readUntilDelimiter(delimiter, in: chars, from: idx) else { return nil }
            args.append(value)
            idx = after
        }
        return (args, idx)
    }

    private static func readUntilDelimiter(
        _ delimiter: String,
        in chars: [Character],
        from start: Int
    ) -> (String, Int)? {
        var depth = 0
        var idx = start
        while idx <= chars.count {
            if depth == 0, let after = matchDelimiter(delimiter, in: chars, at: idx) {
                return (stripSingleGroup(String(chars[start..<idx])), after)
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

    private static func stripSingleGroup(_ text: String) -> String {
        let chars = Array(text)
        guard chars.first == "{", let (inner, after) = readBracedGroup(chars, at: 0), after == chars.count else { return text }
        return inner
    }
}
