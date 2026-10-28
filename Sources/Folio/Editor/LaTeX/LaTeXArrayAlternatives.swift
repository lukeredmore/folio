import Foundation

/// A macro body that only lays out one argument as a one-column `array` between `\left` and
/// `\right` delimiters, such as clqr's `\xorGOO{a\\b}{\}}`. The prose renderer cannot lay out an
/// array, so it shows the `\\`-separated rows of that argument: stacked when the array has no
/// opening delimiter, and on one line as `{a | b}` when it has one.
struct LaTeXArrayAlternatives: Equatable, Sendable {
    enum Delimiter: Equatable, Sendable {
        case text(String)
        /// The delimiter is the macro argument with this 1-based number, as in `\right#2`.
        case argument(Int)
    }

    /// 1-based number of the argument that holds the rows.
    let rowsArgument: Int
    let opening: [Delimiter]
    let closing: [Delimiter]

    /// Parses `body`. Returns nil unless the body is only optional `\text{..}` and math wrappers
    /// around `\left`.. `\begin{array}{..}#n\end{array}` `\right`.., with `%` comments,
    /// spaces, and thin-space commands between them.
    static func parse(_ body: String) -> LaTeXArrayAlternatives? {
        guard body.contains("\\begin{array}") else { return nil }
        var chars = Array(normalized(body))
        chars = unwrapped(chars)
        var idx = 0
        var opening: [Delimiter] = []
        while hasControlWord(chars, "\\left", at: idx) {
            guard let (delimiter, after) = readDelimiter(chars, at: idx + 5) else { return nil }
            opening.append(delimiter)
            idx = after
        }
        guard hasPrefix(chars, "\\begin{array}", at: idx) else { return nil }
        idx += 13
        if let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: idx) { idx = after }
        guard let (_, afterSpec) = LaTeXMacroExpander.readBracedGroup(chars, at: idx), afterSpec + 1 < chars.count,
            chars[afterSpec] == "#", let rows = chars[afterSpec + 1].wholeNumberValue, rows >= 1
        else { return nil }
        idx = afterSpec + 2
        guard hasPrefix(chars, "\\end{array}", at: idx) else { return nil }
        idx += 11
        var closing: [Delimiter] = []
        while hasControlWord(chars, "\\right", at: idx) {
            guard let (delimiter, after) = readDelimiter(chars, at: idx + 6) else { return nil }
            closing.append(delimiter)
            idx = after
        }
        guard idx == chars.count else { return nil }
        return LaTeXArrayAlternatives(rowsArgument: rows, opening: opening, closing: closing)
    }

    /// The text of a delimiter token such as `\{`, `.`, or `\rangle`.
    static func text(ofDelimiter token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let names: [String: String] = [
            ".": "", "\\{": "{", "\\}": "}", "\\lbrace": "{", "\\rbrace": "}", "|": "|", "\\vert": "|",
            "\\lvert": "|", "\\rvert": "|", "\\|": "‖", "\\Vert": "‖", "\\langle": "⟨", "\\rangle": "⟩",
            "(": "(", ")": ")", "[": "[", "]": "]", "/": "/", "\\lbrack": "[", "\\rbrack": "]"
        ]
        return names[trimmed]
    }

    /// The text of a delimiter argument such as `\}` or `.`, and the `^{..}` or `_{..}` script
    /// that may follow it, as in clqr's `\}^{\!*}`.
    static func delimiterArgument(_ argument: String) -> (text: String, script: String?)? {
        let chars = Array(argument.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return nil }
        let (token, after): (String, Int) = chars[0] == "\\" ? LaTeXMacroExpander.readControlWord(chars, at: 0) : (String(chars[0]), 1)
        guard let text = text(ofDelimiter: token) else { return nil }
        let rest = String(chars[after...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return (text, nil) }
        guard rest.first == "^" || rest.first == "_" else { return nil }
        return (text, rest)
    }

    /// Splits `text` at the `\\` row breaks that are not inside braces. Rows are trimmed, and
    /// empty rows are dropped.
    static func rows(of text: String) -> [String] {
        let chars = Array(text)
        var rows: [String] = []
        var current: [Character] = []
        var depth = 0
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\\" && idx + 1 < chars.count {
                if chars[idx + 1] == "\\" && depth == 0 {
                    rows.append(String(current))
                    current = []
                    idx += 2
                    if idx < chars.count && chars[idx] == "*" { idx += 1 }
                    let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                    if let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) { idx = after }
                    continue
                }
                current.append(contentsOf: chars[idx...(idx + 1)])
                idx += 2
                continue
            }
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1 }
            current.append(ch)
            idx += 1
        }
        rows.append(String(current))
        return rows.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Removes `%` comments, whitespace, and the thin-space commands `\!`, `\,`, `\;`, and `\:`.
    private static func normalized(_ body: String) -> String {
        let chars = Array(body)
        var out: [Character] = []
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "%" {
                while idx < chars.count && chars[idx] != "\n" { idx += 1 }
                continue
            }
            if ch.isWhitespace {
                idx += 1
                continue
            }
            if ch == "\\" && idx + 1 < chars.count {
                if ["!", ",", ";", ":"].contains(chars[idx + 1]) {
                    idx += 2
                    continue
                }
                out.append(contentsOf: chars[idx...(idx + 1)])
                idx += 2
                continue
            }
            out.append(ch)
            idx += 1
        }
        return String(out)
    }

    /// Strips `\text{..}`, `\mbox{..}`, `\ensuremath{..}`, `{..}`, `\(..\)`, and `$..$` when they
    /// wrap the whole body.
    private static func unwrapped(_ input: [Character]) -> [Character] {
        var chars = input
        while true {
            if let inner = wholeGroup(chars, prefixes: ["\\text", "\\mbox", "\\ensuremath", ""]) {
                chars = inner
            } else if hasPrefix(chars, "\\(", at: 0), chars.count >= 4, String(chars.suffix(2)) == "\\)" {
                chars = Array(chars[2..<(chars.count - 2)])
            } else if chars.count >= 2, chars.first == "$", chars.last == "$", chars[1] != "$" {
                chars = Array(chars[1..<(chars.count - 1)])
            } else {
                return chars
            }
        }
    }

    private static func wholeGroup(_ chars: [Character], prefixes: [String]) -> [Character]? {
        for prefix in prefixes where hasPrefix(chars, prefix + "{", at: 0) {
            let open = prefix.count
            guard let (inner, after) = LaTeXMacroExpander.readBracedGroup(chars, at: open), after == chars.count else { continue }
            return Array(inner)
        }
        return nil
    }

    private static func readDelimiter(_ chars: [Character], at start: Int) -> (Delimiter, Int)? {
        guard start < chars.count else { return nil }
        if chars[start] == "#", start + 1 < chars.count, let number = chars[start + 1].wholeNumberValue {
            return (.argument(number), start + 2)
        }
        let (word, after): (String, Int) =
            chars[start] == "\\" ? LaTeXMacroExpander.readControlWord(chars, at: start) : (String(chars[start]), start + 1)
        guard let text = text(ofDelimiter: word) else { return nil }
        return (.text(text), after)
    }

    private static func hasControlWord(_ chars: [Character], _ word: String, at idx: Int) -> Bool {
        let end = idx + word.count
        return hasPrefix(chars, word, at: idx) && (end >= chars.count || !chars[end].isLetter)
    }

    private static func hasPrefix(_ chars: [Character], _ prefix: String, at idx: Int) -> Bool {
        let pattern = Array(prefix)
        guard idx + pattern.count <= chars.count else { return false }
        return Array(chars[idx..<(idx + pattern.count)]) == pattern
    }
}

extension LaTeXProseMacroExpander.Renderer {
    /// Renders an array-alternatives macro call with its arguments `args`.
    mutating func renderArrayAlternatives(
        _ layout: LaTeXArrayAlternatives,
        args: [String],
        style: LaTeXProseStyle,
        depth: Int
    ) -> Bool {
        guard layout.rowsArgument <= args.count else { return false }
        func resolve(_ delimiters: [LaTeXArrayAlternatives.Delimiter]) -> (text: String, script: String?)? {
            var text = ""
            var script: String?
            for delimiter in delimiters {
                switch delimiter {
                case .text(let value): text += value
                case .argument(let number):
                    guard number >= 1, number <= args.count, let value = LaTeXArrayAlternatives.delimiterArgument(args[number - 1]) else {
                        return nil
                    }
                    text += value.text
                    script = value.script ?? script
                }
            }
            return (text, script)
        }
        guard let (opening, _) = resolve(layout.opening), let (closing, closingScript) = resolve(layout.closing) else { return false }
        let rows = LaTeXArrayAlternatives.rows(of: args[layout.rowsArgument - 1])
        guard !rows.isEmpty else { return false }
        let stacked = opening.isEmpty
        if !opening.isEmpty { emit(opening, style: style) }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                if stacked {
                    appendLineBreak()
                } else {
                    emit(" | ", style: style)
                }
            }
            var rowStyle = style
            guard render(Array(row), style: &rowStyle, depth: depth + 1) else { return false }
        }
        if !closing.isEmpty { emit(closing, style: style) }
        if let closingScript { appendMath("{}" + closingScript, style: style) }
        return true
    }
}
