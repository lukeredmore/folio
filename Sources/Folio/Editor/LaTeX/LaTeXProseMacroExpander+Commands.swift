import Foundation

/// How the prose renderer handles one built-in text-mode command.
private enum LaTeXProseCommand: Sendable {
    enum NumComparison: Sendable {
        case greater
        case equal
        case less
    }

    /// Renders one argument with the changed style.
    case style(@Sendable (inout LaTeXProseStyle) -> Void)
    /// Changes the style until the enclosing group ends.
    case declaration(@Sendable (inout LaTeXProseStyle) -> Void)
    /// Skips `braces` arguments, then up to `brackets` optional arguments, and renders the next
    /// argument unchanged.
    case wrapper(braces: Int, brackets: Int, appendSpace: Bool = false)
    /// Consumes up to `brackets` optional arguments and `braces` arguments, and renders nothing.
    case drop(brackets: Int, braces: Int)
    case symbol(String)
    case par
    case hspace
    case url
    case href
    case color
    case textcolor
    case ifstrequal
    case ifblank(trimmed: Bool)
    case ifdef(checkEmpty: Bool)
    case ifnum(NumComparison)
    case foreachLoop
    case beginGroup
    case endGroup
    case math
    case fontFamily
    case fontSeries
    case fontShape
    case dimension
    /// Skips a TeX integer such as `-5`, as `\penalty` takes.
    case integer
}

private let iconSymbols: [String: String] = [
    "faAt": "@",
    "faEnvelope": "✉",
    "faEnvelopeO": "✉",
    "faPhone": "☎",
    "faMobile": "☎",
    "faMapMarker": "📍",
    "faMapPin": "📍",
    "faCalendar": "📅",
    "faCalendarO": "📅",
    "faChain": "🔗",
    "faLink": "🔗",
    "faGlobe": "🌐",
    "faHome": "⌂",
    "faLinkedin": "in",
    "faLinkedinSquare": "in",
    "faTwitter": "𝕏",
    "faGithub": "⌘",
    "faGithubAlt": "⌘",
    "faCircle": "●",
    "faCircleO": "○",
    "faBook": "📖",
    "faFileText": "📄",
    "faFileTextO": "📄",
    "faGroup": "👥",
    "faUsers": "👥",
    "faGraduationCap": "🎓",
    "faUniversity": "🎓",
    "faInstitution": "🎓",
    "faBriefcase": "💼",
    "faTrophy": "🏆",
    "faAward": "🏆",
    "faStar": "★",
    "faStarO": "☆",
    "faCheck": "✓",
    "faCogs": "⚙",
    "faCog": "⚙",
    "faWrench": "⚙",
    "faCode": "⟨/⟩",
    "faInfoCircle": "ℹ",
    "aiOrcid": "iD",
    "orcid": "iD"
]

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
            $0.sans = true
            $0.monospace = false
        },
        "textrm": .style {
            $0.sans = false
            $0.monospace = false
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
            $0.italic = false
            $0.smallCaps = false
        },
        "scshape": .declaration { $0.smallCaps = true },
        "ttfamily": .declaration { $0.monospace = true },
        "sffamily": .declaration {
            $0.sans = true
            $0.monospace = false
        },
        "rmfamily": .declaration {
            $0.sans = false
            $0.monospace = false
        },
        "bf": .declaration {
            resetFont(&$0)
            $0.bold = true
        },
        "it": .declaration {
            resetFont(&$0)
            $0.italic = true
        },
        "sl": .declaration {
            resetFont(&$0)
            $0.italic = true
        },
        "sc": .declaration {
            resetFont(&$0)
            $0.smallCaps = true
        },
        "tt": .declaration {
            resetFont(&$0)
            $0.monospace = true
        },
        "sf": .declaration {
            resetFont(&$0)
            $0.sans = true
        },
        "rm": .declaration {
            resetFont(&$0)
        },
        "normalfont": .declaration { resetFont(&$0) },
        "normalcolor": .declaration { $0.colorName = nil },
        "text": .wrapper(braces: 0, brackets: 0),
        "mbox": .wrapper(braces: 0, brackets: 0),
        "hbox": .wrapper(braces: 0, brackets: 0),
        "fbox": .wrapper(braces: 0, brackets: 0),
        "makebox": .wrapper(braces: 0, brackets: 2, appendSpace: true),
        "framebox": .wrapper(braces: 0, brackets: 2, appendSpace: true),
        "raisebox": .wrapper(braces: 1, brackets: 2),
        "colorbox": .wrapper(braces: 1, brackets: 0),
        "textcolor": .textcolor,
        "color": .color,
        "url": .url,
        "href": .href,
        "par": .par,
        "hspace": .hspace,
        "ifstrequal": .ifstrequal,
        "ifblank": .ifblank(trimmed: true),
        "ifstrempty": .ifblank(trimmed: false),
        "ifdef": .ifdef(checkEmpty: false),
        "ifdefempty": .ifdef(checkEmpty: true),
        "ifnumgreater": .ifnum(.greater),
        "ifnumequal": .ifnum(.equal),
        "ifnumless": .ifnum(.less),
        "foreach": .foreachLoop,
        "begingroup": .beginGroup,
        "endgroup": .endGroup,
        "index": .drop(brackets: 0, braces: 1),
        "label": .drop(brackets: 0, braces: 1),
        "phantom": .drop(brackets: 0, braces: 1),
        "hphantom": .drop(brackets: 0, braces: 1),
        "vphantom": .drop(brackets: 0, braces: 1),
        "rule": .drop(brackets: 1, braces: 2),
        "marginpar": .drop(brackets: 1, braces: 1),
        "afterpage": .drop(brackets: 0, braces: 1),
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
        "ignorespaces", "protect", "noindent", "null", "smash", "smallskip", "medskip", "bigskip",
        "raggedright", "raggedleft", "centering", "arraybackslash"
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
    for (name, glyph) in iconSymbols {
        table[name] = .symbol(glyph)
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

    static func applyCustomFont(_ decl: LaTeXFontDeclaration, to style: inout LaTeXProseStyle) {
        if let family = decl.fontFamily, !family.isEmpty {
            style.fontFamily = family
            style.monospace = false
            style.sans = false
        }
        if let scale = decl.sizeScale {
            style.sizeScale = scale
        }
        if let bold = decl.bold {
            style.bold = bold
        }
        if let italic = decl.italic {
            style.italic = italic
        }
        if let smallCaps = decl.smallCaps {
            style.smallCaps = smallCaps
        }
        if let letterSpaceEm = decl.letterSpaceEm {
            style.letterSpaceEm = letterSpaceEm
        }
    }

    /// The text that a built-in command without arguments prints in a prose line, such as
    /// "Contents" for `\contentsname` or "©" for `\copyright`. Nil for other commands.
    static func builtinText(forCommand name: String) -> String? {
        if let text = documentNames[name] { return text }
        if let icon = iconSymbols[name] { return icon }
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
    style.fontFamily = nil
    style.letterSpaceEm = 0
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
            var nestedStyle: LaTeXProseStyle? = style
            let end = expandUserMacro(chars, at: idx, style: &nestedStyle, depth: depth)
            if let updated = nestedStyle { style = updated }
            return end
        }
        let cmdBase = String(word.dropFirst())
        guard let command = proseCommands[cmdBase] else {
            if Self.isIconControlWord(cmdBase) {
                emit("•", style: style)
                return LaTeXMacroExpander.skipSpaces(chars, from: hasStar ? afterWord + 1 : afterWord)
            }
            return nil
        }
        // TeX skips the spaces after a control word.
        let after = LaTeXMacroExpander.skipSpaces(chars, from: hasStar ? afterWord + 1 : afterWord)
        return renderBuiltin(command, chars, after: after, style: &style, depth: depth)
    }

    private static func isIconControlWord(_ name: String) -> Bool {
        guard (name.hasPrefix("fa") || name.hasPrefix("ai")), name.count > 2 else { return false }
        return name[name.index(name.startIndex, offsetBy: 2)].isUppercase
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
        case .wrapper(let braces, let brackets, let appendSpace):
            var idx = start
            for _ in 0..<braces {
                guard let (_, end) = readArgument(chars, at: idx) else { return nil }
                idx = end
            }
            idx = skipBrackets(chars, from: idx, limit: brackets)
            guard let (arg, end) = readArgument(chars, at: idx) else { return nil }
            var argStyle = style
            guard render(Array(arg), style: &argStyle, depth: depth) else { return nil }
            if appendSpace && hasVisibleTextOnCurrentLine {
                var spaceStyle = LaTeXProseStyle()
                spaceStyle.sizeScale = style.sizeScale
                emit("\u{2003}", style: spaceStyle)
            }
            return end
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
        case .par:
            appendParagraphBreak()
            return start
        case .hspace:
            var idx = start
            if idx < chars.count && chars[idx] == "*" { idx = LaTeXMacroExpander.skipSpaces(chars, from: idx + 1) }
            guard let (arg, end) = readArgument(chars, at: idx) else { return nil }
            if hasVisibleTextOnCurrentLine, let pts = LaTeXLength.parse(arg)?.resolvedPoints(baseSize: 10), pts > 0 {
                var spaceStyle = LaTeXProseStyle()
                spaceStyle.sizeScale = style.sizeScale
                emit(pts >= 12.0 ? "\u{2003}" : " ", style: spaceStyle)
            }
            return end
        case .url:
            guard let (rawURL, end) = readRawBracedGroup(chars, at: start) else { return nil }
            var urlStyle = style
            urlStyle.monospace = true
            urlStyle.underline = true
            if urlStyle.colorName == nil { urlStyle.colorName = "accent" }
            emit(rawURL.trimmingCharacters(in: .whitespacesAndNewlines), style: urlStyle)
            return end
        case .href:
            guard let (_, afterURL) = readRawBracedGroup(chars, at: start),
                let (label, end) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: afterURL))
            else { return nil }
            var linkStyle = style
            linkStyle.underline = true
            if linkStyle.colorName == nil { linkStyle.colorName = "accent" }
            return render(Array(label), style: &linkStyle, depth: depth) ? end : nil
        case .color:
            var idx = start
            let hasModel: Bool
            let afterOpt = skipBrackets(chars, from: idx, limit: 1)
            hasModel = afterOpt != idx
            idx = afterOpt
            guard let (spec, end) = readArgument(chars, at: idx) else { return nil }
            if !hasModel {
                let name = spec.trimmingCharacters(in: .whitespacesAndNewlines)
                style.colorName = name == "normalcolor" ? nil : name
            }
            return end
        case .textcolor:
            var idx = start
            let afterOpt = skipBrackets(chars, from: idx, limit: 1)
            let hasModel = afterOpt != idx
            idx = afterOpt
            guard let (spec, afterSpec) = readArgument(chars, at: idx),
                let (body, end) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: afterSpec))
            else { return nil }
            var argStyle = style
            if !hasModel {
                argStyle.colorName = spec.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return render(Array(body), style: &argStyle, depth: depth) ? end : nil
        case .ifstrequal:
            guard let (lhs, a1) = readArgument(chars, at: start),
                let (rhs, a2) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a1)),
                let (thenB, a3) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a2)),
                let (elseB, end) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a3))
            else { return nil }
            let branch = lhs.trimmingCharacters(in: .whitespacesAndNewlines) == rhs.trimmingCharacters(in: .whitespacesAndNewlines) ? thenB : elseB
            return render(Array(branch), style: &style, depth: depth) ? end : nil
        case .ifblank(let trimmed):
            guard let (arg, a1) = readArgument(chars, at: start),
                let (thenB, a2) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a1)),
                let (elseB, end) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a2))
            else { return nil }
            let isBlank = trimmed ? arg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : arg.isEmpty
            let branch = isBlank ? thenB : elseB
            return render(Array(branch), style: &style, depth: depth) ? end : nil
        case .ifdef(let checkEmpty):
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: start)
            guard let (cmdName, a1) = LaTeXMacroExpander.readMacroNameArg(chars, at: probe),
                let (thenB, a2) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a1)),
                let (elseB, end) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a2))
            else { return nil }
            let def = macros[cmdName]
            let cond: Bool
            if checkEmpty {
                cond = def?.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            } else {
                cond = def != nil
            }
            let branch = cond ? thenB : elseB
            return render(Array(branch), style: &style, depth: depth) ? end : nil
        case .ifnum(let op):
            guard let (lhsStr, a1) = readArgument(chars, at: start),
                let (rhsStr, a2) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a1)),
                let (thenB, a3) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a2)),
                let (elseB, end) = readArgument(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: a3)),
                let lhs = Int(lhsStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                let rhs = Int(rhsStr.trimmingCharacters(in: .whitespacesAndNewlines))
            else { return nil }
            let matched: Bool
            switch op {
            case .greater: matched = lhs > rhs
            case .equal: matched = lhs == rhs
            case .less: matched = lhs < rhs
            }
            let branch = matched ? thenB : elseB
            return render(Array(branch), style: &style, depth: depth) ? end : nil
        case .foreachLoop:
            return renderForeachLoop(chars, from: start, style: &style, depth: depth)
        case .beginGroup:
            groupStack.append(style)
            return start
        case .endGroup:
            if !groupStack.isEmpty {
                style = groupStack.removeLast()
            }
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

    private func readRawBracedGroup(_ chars: [Character], at start: Int) -> (String, Int)? {
        let open = LaTeXMacroExpander.skipSpaces(chars, from: start)
        guard open < chars.count, chars[open] == "{" else { return nil }
        var depth = 0
        var idx = open
        while idx < chars.count {
            if chars[idx] == "{" {
                depth += 1
            } else if chars[idx] == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(chars[(open + 1)..<idx]), idx + 1)
                }
            }
            idx += 1
        }
        return nil
    }

    private mutating func renderForeachLoop(
        _ chars: [Character],
        from start: Int,
        style: inout LaTeXProseStyle,
        depth: Int
    ) -> Int? {
        let varStart = LaTeXMacroExpander.skipSpaces(chars, from: start)
        guard varStart < chars.count, chars[varStart] == "\\" else { return nil }
        let (varName, afterVar) = LaTeXMacroExpander.readControlWord(chars, at: varStart)
        guard varName.count > 1 else { return nil }
        var idx = LaTeXMacroExpander.skipSpaces(chars, from: afterVar)
        guard idx + 1 < chars.count, chars[idx] == "i", chars[idx + 1] == "n" else { return nil }
        idx = LaTeXMacroExpander.skipSpaces(chars, from: idx + 2)
        guard let (rawList, afterList) = LaTeXMacroExpander.readBracedGroup(chars, at: idx) else { return nil }
        idx = LaTeXMacroExpander.skipSpaces(chars, from: afterList)
        guard let (body, end) = LaTeXMacroExpander.readBracedGroup(chars, at: idx) else { return nil }
        let items = Self.expandForeachItems(rawList)
        for item in items {
            let expanded = Self.substituteLoopVar(varName, with: item, in: body)
            expandedBudget -= expanded.count
            guard expandedBudget >= 0, render(Array(expanded), style: &style, depth: depth) else { return nil }
        }
        return end
    }

    private static func expandForeachItems(_ rawList: String) -> [String] {
        let parts = rawList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count == 3, parts[1] == "...", let start = Int(parts[0]), let end = Int(parts[2]) {
            if start <= end {
                return (start...end).prefix(32).map(String.init)
            }
            return stride(from: start, through: end, by: -1).prefix(32).map(String.init)
        }
        return Array(parts.prefix(32))
    }

    private static func substituteLoopVar(_ varName: String, with value: String, in body: String) -> String {
        let bodyChars = Array(body)
        let needle = Array(varName)
        var result: [Character] = []
        var i = 0
        while i < bodyChars.count {
            if i + needle.count <= bodyChars.count && Array(bodyChars[i..<(i + needle.count)]) == needle {
                let nextIdx = i + needle.count
                let followedByLetter = nextIdx < bodyChars.count && (bodyChars[nextIdx].isLetter || bodyChars[nextIdx] == "@")
                if !followedByLetter {
                    result += value
                    i = nextIdx
                    continue
                }
            }
            result.append(bodyChars[i])
            i += 1
        }
        return String(result)
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
