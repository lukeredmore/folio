import Foundation

/// How the prose renderer handles one built-in text-mode command.
private enum LaTeXProseCommand: Sendable {
    /// Renders one argument with the changed style.
    case style(@Sendable (inout LaTeXProseStyle) -> Void)
    /// Changes the style until the enclosing group ends.
    case declaration(@Sendable (inout LaTeXProseStyle) -> Void)
    /// Skips `braces` arguments, then up to `brackets` optional arguments, and renders the next
    /// argument unchanged.
    case wrapper(braces: Int, brackets: Int)
    /// Consumes up to `brackets` optional arguments and `braces` arguments, and renders nothing.
    case drop(brackets: Int, braces: Int)
    case symbol(String)
    case math
    case fontFamily
    case fontSeries
    case fontShape
    case dimension
    /// Skips a TeX integer such as `-5`, as `\penalty` takes.
    case integer
}

private let proseCommands: [String: LaTeXProseCommand] = {
    var table: [String: LaTeXProseCommand] = [
        "textbf": .style { $0.bold = true },
        "textmd": .style { $0.bold = false },
        "textit": .style { $0.italic = true },
        "textsl": .style { $0.italic = true },
        "emph": .style { $0.italic.toggle() },
        "textup": .style { $0.italic = false },
        "texttt": .style { $0.monospace = true },
        "textsf": .style {
            $0.sans = true; $0.monospace = false
        },
        "textrm": .style {
            $0.sans = false; $0.monospace = false
        },
        "textsc": .style { $0.smallCaps = true },
        "textnormal": .style { resetFont(&$0) },
        "underline": .style { $0.underline = true },
        "uline": .style { $0.underline = true },
        "textsubscript": .style { $0.script = .lowered },
        "textsuperscript": .style { $0.script = .raised },
        "lowercase": .style { $0.letterCase = .lower },
        "MakeLowercase": .style { $0.letterCase = .lower },
        "uppercase": .style { $0.letterCase = .upper },
        "MakeUppercase": .style { $0.letterCase = .upper },
        "MakeTextUppercase": .style { $0.letterCase = .upper },
        "bfseries": .declaration { $0.bold = true },
        "mdseries": .declaration { $0.bold = false },
        "itshape": .declaration { $0.italic = true },
        "slshape": .declaration { $0.italic = true },
        "em": .declaration { $0.italic.toggle() },
        "upshape": .declaration {
            $0.italic = false; $0.smallCaps = false
        },
        "scshape": .declaration { $0.smallCaps = true },
        "ttfamily": .declaration { $0.monospace = true },
        "sffamily": .declaration {
            $0.sans = true; $0.monospace = false
        },
        "rmfamily": .declaration {
            $0.sans = false; $0.monospace = false
        },
        "normalfont": .declaration { resetFont(&$0) },
        "text": .wrapper(braces: 0, brackets: 0),
        "mbox": .wrapper(braces: 0, brackets: 0),
        "hbox": .wrapper(braces: 0, brackets: 0),
        "fbox": .wrapper(braces: 0, brackets: 0),
        "makebox": .wrapper(braces: 0, brackets: 2),
        "framebox": .wrapper(braces: 0, brackets: 2),
        "raisebox": .wrapper(braces: 1, brackets: 2),
        "textcolor": .wrapper(braces: 1, brackets: 0),
        "colorbox": .wrapper(braces: 1, brackets: 0),
        "index": .drop(brackets: 0, braces: 1),
        "label": .drop(brackets: 0, braces: 1),
        "hspace": .drop(brackets: 0, braces: 1),
        "phantom": .drop(brackets: 0, braces: 1),
        "hphantom": .drop(brackets: 0, braces: 1),
        "vphantom": .drop(brackets: 0, braces: 1),
        "color": .drop(brackets: 1, braces: 1),
        "rule": .drop(brackets: 1, braces: 2),
        "fontsize": .drop(brackets: 0, braces: 2),
        "setlength": .drop(brackets: 0, braces: 2),
        "addtolength": .drop(brackets: 0, braces: 2),
        "settowidth": .drop(brackets: 0, braces: 2),
        "ensuremath": .math,
        "fontfamily": .fontFamily,
        "fontseries": .fontSeries,
        "fontshape": .fontShape,
        "hskip": .dimension,
        "kern": .dimension,
        "penalty": .integer
    ]
    let sizes: [(String, Double)] = [
        ("tiny", 0.7), ("scriptsize", 0.75), ("footnotesize", 0.85), ("small", 0.92), ("normalsize", 1.0),
        ("large", 1.1), ("Large", 1.2), ("LARGE", 1.3), ("huge", 1.4), ("Huge", 1.4)
    ]
    for (name, scale) in sizes {
        table[name] = .declaration { $0.sizeScale = scale }
    }
    let ignored = [
        "selectfont", "boldmath", "unboldmath", "unskip", "relax", "nobreak", "strut", "leavevmode",
        "ignorespaces", "protect", "noindent", "null", "smash"
    ]
    for name in ignored {
        table[name] = .symbol("")
    }
    let symbols: [String: String] = [
        "ldots": "…", "dots": "…", "textellipsis": "…", "textasciitilde": "~", "textasteriskcentered": "∗",
        "textbackslash": "\\", "textbar": "|", "textendash": "–", "textemdash": "—", "textquoteleft": "‘",
        "textquoteright": "’", "copyright": "©", "textcopyright": "©", "S": "§", "P": "¶", "dag": "†",
        "ddag": "‡", "LaTeX": "LaTeX", "TeX": "TeX", "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}",
        "enspace": "\u{2002}", "thinspace": "\u{2009}", "space": " ", "hfill": " ", "hfil": " ",
        "textunderscore": "_", "textless": "<", "textgreater": ">", "slash": "/", "textbullet": "•"
    ]
    for (name, text) in symbols.merging(documentNames, uniquingKeysWith: { first, _ in first }) {
        table[name] = .symbol(text)
    }
    return table
}()

/// The names that LaTeX classes print, in English.
private let documentNames: [String: String] = [
    "contentsname": "Contents", "indexname": "Index", "refname": "References", "bibname": "Bibliography",
    "figurename": "Figure", "tablename": "Table", "abstractname": "Abstract", "appendixname": "Appendix",
    "chaptername": "Chapter", "partname": "Part", "listfigurename": "List of Figures", "listtablename": "List of Tables",
    "proofname": "Proof", "seename": "see", "alsoname": "see also", "ccname": "cc", "enclname": "encl", "pagename": "Page",
    "headtoname": "To", "glossaryname": "Glossary"
]

/// Text-mode symbols that the styler draws in prose lines outside macro expansions.
private let proseLineSymbols: Set<String> = [
    "ldots", "dots", "textellipsis", "textasciitilde", "textasteriskcentered", "textbar", "textendash", "textemdash",
    "textquoteleft", "textquoteright", "copyright", "textcopyright", "S", "P", "dag", "ddag", "textunderscore",
    "textless", "textgreater", "textbullet", "quad", "qquad", "enspace", "thinspace"
]

extension LaTeXProseMacroExpander {
    /// Applies the built-in font declaration `name`, such as `itshape` or `large`, to `style`.
    /// Returns false when `name` is not a declaration.
    static func applyDeclaration(_ name: String, to style: inout LaTeXProseStyle) -> Bool {
        guard case .declaration(let change)? = proseCommands[name] else { return false }
        change(&style)
        return true
    }

    /// Applies `\fontfamily`, `\fontseries`, or `\fontshape` with `value` to `style`.
    static func applyFontSelection(_ name: String, value: String, to style: inout LaTeXProseStyle) {
        guard let command = proseCommands[name] else { return }
        Renderer.applyFontSelection(command, value: value.trimmingCharacters(in: .whitespaces), to: &style)
    }

    /// The text that a built-in command without arguments prints in a prose line, such as
    /// "Contents" for `\contentsname` or "©" for `\copyright`. Nil for other commands.
    static func builtinText(forCommand name: String) -> String? {
        if let text = documentNames[name] { return text }
        guard proseLineSymbols.contains(name), case .symbol(let text)? = proseCommands[name] else { return nil }
        return text
    }
}

private func resetFont(_ style: inout LaTeXProseStyle) {
    style.bold = false
    style.italic = false
    style.monospace = false
    style.sans = false
    style.smallCaps = false
}

extension LaTeXProseMacroExpander.Renderer {
    /// Renders the command at `chars[idx]`, a backslash. Returns the index after it and its
    /// arguments, or nil when the command is unknown or malformed.
    mutating func renderCommand(
        _ chars: [Character],
        at idx: Int,
        style: inout LaTeXProseStyle,
        depth: Int
    ) -> Int? {
        guard idx + 1 < chars.count else { return nil }
        let next = chars[idx + 1]
        guard next.isLetter || next == "@" else { return renderControlSymbol(chars, at: idx, style: style) }
        let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: idx)
        let hasStar = afterWord < chars.count && chars[afterWord] == "*"
        let callName = String(word.dropFirst()) + (hasStar ? "*" : "")
        if LaTeXProseMacroExpander.definition(forCall: callName, in: macros) != nil {
            return expandUserMacro(chars, at: idx, style: style, depth: depth)
        }
        guard let command = proseCommands[String(word.dropFirst())] else { return nil }
        // TeX skips the spaces after a control word.
        let after = LaTeXMacroExpander.skipSpaces(chars, from: hasStar ? afterWord + 1 : afterWord)
        return renderBuiltin(command, chars, after: after, style: &style, depth: depth)
    }

    private mutating func renderBuiltin(
        _ command: LaTeXProseCommand,
        _ chars: [Character],
        after start: Int,
        style: inout LaTeXProseStyle,
        depth: Int
    ) -> Int? {
        switch command {
        case .style(let change):
            guard let (arg, end) = readArgument(chars, at: start) else { return nil }
            var argStyle = style
            change(&argStyle)
            return render(Array(arg), style: &argStyle, depth: depth) ? end : nil
        case .declaration(let change):
            change(&style)
            return start
        case .wrapper(let braces, let brackets):
            var idx = start
            for _ in 0..<braces {
                guard let (_, end) = readArgument(chars, at: idx) else { return nil }
                idx = end
            }
            idx = skipBrackets(chars, from: idx, limit: brackets)
            guard let (arg, end) = readArgument(chars, at: idx) else { return nil }
            var argStyle = style
            return render(Array(arg), style: &argStyle, depth: depth) ? end : nil
        case .drop(let brackets, let braces):
            var idx = skipBrackets(chars, from: start, limit: brackets)
            for _ in 0..<braces {
                guard let (_, end) = readArgument(chars, at: idx) else { return nil }
                idx = end
            }
            return idx
        case .symbol(let text):
            if !text.isEmpty { emit(text, style: style) }
            return start
        case .math:
            guard let (arg, end) = readArgument(chars, at: start) else { return nil }
            appendMath(arg, style: style)
            return end
        case .fontFamily, .fontSeries, .fontShape:
            guard let (arg, end) = readArgument(chars, at: start) else { return nil }
            Self.applyFontSelection(command, value: arg.trimmingCharacters(in: .whitespaces), to: &style)
            return end
        case .dimension:
            return Self.skipDimension(chars, from: start)
        case .integer:
            var idx = start
            if idx < chars.count && (chars[idx] == "-" || chars[idx] == "+") { idx += 1 }
            let digits = idx
            while idx < chars.count && chars[idx].isNumber { idx += 1 }
            return idx > digits ? idx : nil
        }
    }

    private mutating func renderControlSymbol(_ chars: [Character], at idx: Int, style: LaTeXProseStyle) -> Int? {
        let symbol = chars[idx + 1]
        switch symbol {
        case "\\":
            appendLineBreak()
            var p = idx + 2
            if p < chars.count && chars[p] == "*" { p += 1 }
            if let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: p) { p = after }
            return p
        case "(":
            var p = idx + 2
            while p + 1 < chars.count {
                if chars[p] == "\\" && chars[p + 1] == ")" {
                    appendMath(String(chars[(idx + 2)..<p]), style: style)
                    return p + 2
                }
                p += chars[p] == "\\" ? 2 : 1
            }
            return nil
        case "&", "%", "$", "#", "_", "{", "}":
            emit(String(symbol), style: style)
        case " ", "\n", "\t":
            emit(" ", style: style)
        case ",":
            emit("\u{2009}", style: style)
        case ";", ":", ">":
            emit("\u{2005}", style: style)
        case "!", "/", "-", "@":
            break
        default:
            return nil
        }
        return idx + 2
    }

    private func readArgument(_ chars: [Character], at start: Int) -> (String, Int)? {
        let idx = LaTeXMacroExpander.skipSpaces(chars, from: start)
        guard idx < chars.count, chars[idx] != "}" else { return nil }
        return LaTeXMacroExpander.readMacroArgument(chars, at: idx)
    }

    private func skipBrackets(_ chars: [Character], from start: Int, limit: Int) -> Int {
        var idx = start
        for _ in 0..<limit {
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            guard let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) else { break }
            idx = after
        }
        return idx
    }

    fileprivate static func applyFontSelection(_ command: LaTeXProseCommand, value: String, to style: inout LaTeXProseStyle) {
        switch command {
        case .fontFamily:
            if ["cmtt", "pcr", "lmtt", "txtt", "cmvtt", "zi4"].contains(value) {
                style.monospace = true
                style.sans = false
            } else if ["cmss", "phv", "lmss", "cmssbx", "qhv"].contains(value) {
                style.sans = true
                style.monospace = false
            } else if ["cmr", "ptm", "lmr", "ppl", "pplx", "bch", "qtm"].contains(value) {
                style.sans = false
                style.monospace = false
            }
        case .fontSeries:
            if ["b", "bx", "sb", "eb", "ub"].contains(value) {
                style.bold = true
            } else if ["m", "l", "c"].contains(value) {
                style.bold = false
            }
        case .fontShape:
            if value == "it" || value == "sl" {
                style.italic = true
            } else if value == "n" || value == "up" {
                style.italic = false
                style.smallCaps = false
            } else if value == "sc" {
                style.smallCaps = true
            }
        default:
            break
        }
    }

    /// Skips a TeX dimension such as `1.4ex`, `-3pt`, or `\ITtab`. Returns nil if none is there.
    private static func skipDimension(_ chars: [Character], from start: Int) -> Int? {
        var idx = start
        if idx < chars.count && (chars[idx] == "-" || chars[idx] == "+") { idx += 1 }
        if idx < chars.count && chars[idx] == "\\" {
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            return word.count > 1 ? after : nil
        }
        let numberStart = idx
        while idx < chars.count && (chars[idx].isNumber || chars[idx] == "." || chars[idx] == ",") { idx += 1 }
        guard idx > numberStart else { return nil }
        idx = LaTeXMacroExpander.skipSpaces(chars, from: idx)
        let unitStart = idx
        while idx < chars.count && chars[idx].isLetter && idx - unitStart < 2 { idx += 1 }
        return idx - unitStart == 2 ? idx : nil
    }
}
