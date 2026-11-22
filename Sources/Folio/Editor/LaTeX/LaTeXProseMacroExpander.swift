import CoreGraphics
import Foundation

/// Text style of one run in an expanded prose macro.
struct LaTeXProseStyle: Hashable, Sendable {
    enum Script: Hashable, Sendable {
        case none
        case lowered
        case raised
    }

    enum LetterCase: Hashable, Sendable {
        case asIs
        case lower
        case upper
    }

    var bold = false
    var italic = false
    var monospace = false
    var sans = false
    var smallCaps = false
    var underline = false
    var script = Script.none
    var sizeScale: CGFloat = 1.0
    var letterCase = LetterCase.asIs
    var fontFamily: String?
    var letterSpaceEm: CGFloat = 0
    var colorName: String?
}

/// One piece of an expanded prose macro: styled text, inline math, or a `\\` line break.
enum LaTeXProseSegment: Hashable, Sendable {
    case text(String, LaTeXProseStyle)
    case math(String, LaTeXProseStyle)
    case lineBreak
}

/// A user macro call in prose and what it renders as.
struct LaTeXProseExpansion: Equatable, Sendable {
    /// UTF-16 length of the call in the source: the name, a `*`, and the arguments it consumed.
    let consumedLength: Int
    let segments: [LaTeXProseSegment]
}

/// Expands user macros in text mode and maps the text-mode commands in the result to styles.
/// Rendering fails, and returns nil, for any command it does not know, so a macro whose body does
/// layout work (`\vspace`, `\item`, `\settowidth` loops) keeps showing its source.
enum LaTeXProseMacroExpander {
    struct Limits: Sendable {
        /// Deepest nesting of user macro expansions.
        var maxDepth = 12
        /// Total characters of macro bodies that one call may substitute, over all nested calls.
        var maxExpandedCharacters = 8_000
        /// Segments that one call may produce.
        var maxSegments = 256
    }

    /// Expands the user macro call that starts at `source[0]`, a backslash. `source` runs to the
    /// end of the line. Returns nil when `macros` has no text-mode definition for the name, the
    /// line does not supply its arguments, or the expansion cannot be rendered.
    static func expandCall(
        source: String,
        macros: [String: LaTeXMacroDefinition],
        limits: Limits = Limits()
    ) -> LaTeXProseExpansion? {
        let chars = Array(source)
        var renderer = Renderer(macros: macros, limits: limits)
        var unusedStyle: LaTeXProseStyle?
        guard let end = renderer.expandUserMacro(chars, at: 0, style: &unusedStyle, depth: 0) else { return nil }
        renderer.trimTrailingWhitespaceAndBreaks()
        guard !renderer.segments.isEmpty else { return nil }
        return LaTeXProseExpansion(
            consumedLength: String(chars[0..<end]).utf16.count,
            segments: renderer.segments
        )
    }

    /// Renders text-mode TeX to segments. Returns nil when the text uses an unknown command or
    /// exceeds `limits`.
    static func render(
        _ tex: String,
        macros: [String: LaTeXMacroDefinition],
        limits: Limits = Limits()
    ) -> [LaTeXProseSegment]? {
        var renderer = Renderer(macros: macros, limits: limits)
        var style = LaTeXProseStyle()
        guard renderer.render(Array(tex), style: &style, depth: 0) else { return nil }
        return renderer.segments
    }

    /// Finds the definition for a call to `name`, which may end in `*`. A starred call uses a
    /// `\name*` definition when one exists. Otherwise a starred call to a macro with arguments
    /// uses `\name` and consumes the star, as `\WithSuffix` variants usually only add side effects.
    static func definition(
        forCall name: String,
        in macros: [String: LaTeXMacroDefinition]
    ) -> (definition: LaTeXMacroDefinition, consumesStar: Bool)? {
        let isStarred = name.hasSuffix("*")
        let base = isStarred ? String(name.dropLast()) : name
        if isStarred, let def = macros["\\\(name)"], isProseDefinition(def) { return (def, true) }
        guard let def = macros["\\\(base)"], isProseDefinition(def) else { return nil }
        let takesArguments = def.argCount > 0 || def.parameterText != nil
        if isStarred && !takesArguments { return (def, false) }
        return (def, isStarred)
    }

    private static func isProseDefinition(_ def: LaTeXMacroDefinition) -> Bool {
        def.operatorText == nil && !def.isEnvironment
    }
}

extension LaTeXProseMacroExpander {
    struct Renderer {
        let macros: [String: LaTeXMacroDefinition]
        let limits: Limits
        var expandedBudget: Int
        /// Output so far. `emit` merges adjacent text with the same style, so the segment cap
        /// counts style runs, not characters.
        var segments: [LaTeXProseSegment] = []
        /// Stack of `\begingroup` styles active inside the current `render` scope.
        var groupStack: [LaTeXProseStyle] = []
        /// Stack of enclosing inline `tabular`/`tabularx` base styles for `&` cell separators.
        var tabularStack: [LaTeXProseStyle] = []
        /// How many math segments enclose this renderer. Text macros inside math are rendered by
        /// a nested renderer, and this bounds the nesting.
        let mathNesting: Int

        init(macros: [String: LaTeXMacroDefinition], limits: Limits, mathNesting: Int = 0) {
            self.macros = macros
            self.limits = limits
            self.mathNesting = mathNesting
            expandedBudget = limits.maxExpandedCharacters
        }

        /// Expands the user macro call at `chars[start]` and renders its body. With a nil
        /// `style`, the body starts from the default style. Returns the index after the call.
        mutating func expandUserMacro(
            _ chars: [Character],
            at start: Int,
            style: inout LaTeXProseStyle?,
            depth: Int
        ) -> Int? {
            let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: start)
            guard word.count > 1 else { return nil }
            let hasStar = afterWord < chars.count && chars[afterWord] == "*"
            let callName = String(word.dropFirst()) + (hasStar ? "*" : "")
            guard depth < limits.maxDepth,
                let (def, consumesStar) = LaTeXProseMacroExpander.definition(forCall: callName, in: macros)
            else { return nil }
            var end = consumesStar ? afterWord + 1 : afterWord
            if let fontDecl = def.fontDeclaration {
                guard var activeStyle = style else { return nil }
                LaTeXProseMacroExpander.applyCustomFont(fontDecl, to: &activeStyle)
                style = activeStyle
                if end + 1 < chars.count && chars[end] == "{" && chars[end + 1] == "}" {
                    end += 2
                } else if !hasStar {
                    end = LaTeXMacroExpander.skipSpaces(chars, from: end)
                }
                return end
            }
            guard
                let (args, afterArgs) = LaTeXMacroExpander.readArguments(for: def, in: chars, from: end)
                    ?? Self.readArgumentsPaddingGuardedTrailingOptionals(for: def, in: chars, from: end)
            else { return nil }
            end = afterArgs
            let takesNoArguments = def.argCount == 0 && def.parameterText == nil && !consumesStar
            if takesNoArguments && style == nil && end + 1 < chars.count && chars[end] == "{" && chars[end + 1] == "}" {
                end += 2
            } else if takesNoArguments && style != nil && !hasStar {
                // Inside a body, TeX skips the spaces after a control word. A call on the source
                // line keeps them, so the line's visible spacing does not change.
                end = LaTeXMacroExpander.skipSpaces(chars, from: end)
            }
            if let layout = LaTeXArrayAlternatives.parse(def.replacement) {
                expandedBudget -= args.reduce(0) { $0 + $1.count }
                guard expandedBudget >= 0, renderArrayAlternatives(layout, args: args, style: style ?? LaTeXProseStyle(), depth: depth) else { return nil }
                return end
            }
            let sanitizedArgs = Self.sanitizeArguments(args, forReplacement: def.replacement)
            let body = LaTeXMacroExpander.substituteArguments(sanitizedArgs, into: def.replacement)
            expandedBudget -= body.count
            guard expandedBudget >= 0 else { return nil }
            var bodyStyle = style ?? LaTeXProseStyle()
            guard render(Array(body), style: &bodyStyle, depth: depth + 1) else { return nil }
            if takesNoArguments && style != nil {
                style = bodyStyle
            }
            return end
        }

        /// Renders `chars` with `style`. Declarations change `style`, so they last until the
        /// enclosing group ends, as in TeX.
        mutating func render(_ chars: [Character], style: inout LaTeXProseStyle, depth: Int) -> Bool {
            let savedStackCount = groupStack.count
            let savedTabularCount = tabularStack.count
            defer {
                while groupStack.count > savedStackCount {
                    groupStack.removeLast()
                }
                while tabularStack.count > savedTabularCount {
                    tabularStack.removeLast()
                }
            }
            var idx = 0
            while idx < chars.count {
                guard segments.count <= limits.maxSegments else { return false }
                guard let next = renderToken(chars, at: idx, style: &style, depth: depth) else { return false }
                idx = next
            }
            return true
        }

        private mutating func renderToken(
            _ chars: [Character],
            at idx: Int,
            style: inout LaTeXProseStyle,
            depth: Int
        ) -> Int? {
            let ch = chars[idx]
            switch ch {
            case "{":
                guard let (inner, after) = LaTeXMacroExpander.readBracedGroup(chars, at: idx) else { return nil }
                var groupStyle = style
                return render(Array(inner), style: &groupStyle, depth: depth) ? after : nil
            case "&":
                guard let tableBaseStyle = tabularStack.last else { return nil }
                style = tableBaseStyle
                emit(hasVisibleTextOnCurrentLine ? "\u{2003}" : "\u{2003}\u{2002}", style: style)
                return LaTeXMacroExpander.skipSpaces(chars, from: idx + 1)
            case "}", "#", "^", "_":
                return nil
            case "$":
                return readDollarMath(chars, at: idx, style: style)
            case "%":
                var p = idx
                while p < chars.count && chars[p] != "\n" { p += 1 }
                return LaTeXMacroExpander.skipSpaces(chars, from: p)
            case "\\":
                return renderCommand(chars, at: idx, style: &style, depth: depth)
            default:
                return renderCharacters(chars, at: idx, style: style)
            }
        }

        private mutating func renderCharacters(_ chars: [Character], at idx: Int, style: LaTeXProseStyle) -> Int {
            let ch = chars[idx]
            if ch.isWhitespace {
                var p = idx
                while p < chars.count && chars[p].isWhitespace { p += 1 }
                if case .lineBreak? = segments.last {
                } else {
                    emit(" ", style: style)
                }
                return p
            }
            if matches("http://", chars, at: idx) || matches("https://", chars, at: idx) || matches("www.", chars, at: idx) {
                var p = idx
                while p < chars.count && Self.isBareURLCharacter(chars[p]) {
                    p += 1
                }
                var urlStyle = style
                urlStyle.underline = true
                if urlStyle.colorName == nil { urlStyle.colorName = "accent" }
                emit(String(chars[idx..<p]), style: urlStyle)
                return p
            }
            let ligatures: [(String, String)] = [("---", "—"), ("--", "–"), ("``", "“"), ("''", "”"), ("`", "‘"), ("'", "’"), ("~", "\u{00A0}")]
            for (pattern, replacement) in ligatures where matches(pattern, chars, at: idx) {
                emit(replacement, style: style)
                return idx + pattern.count
            }
            emit(String(ch), style: style)
            return idx + 1
        }

        private func matches(_ pattern: String, _ chars: [Character], at idx: Int) -> Bool {
            let p = Array(pattern)
            guard idx + p.count <= chars.count else { return false }
            return Array(chars[idx..<(idx + p.count)]) == p
        }

        var hasVisibleTextOnCurrentLine: Bool {
            for segment in segments.reversed() {
                switch segment {
                case .lineBreak:
                    return false
                case let .text(text, _):
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
                case .math:
                    return true
                }
            }
            return false
        }

        mutating func emit(_ text: String, style: LaTeXProseStyle) {
            let cased: String
            switch style.letterCase {
            case .asIs: cased = text
            case .lower: cased = text.lowercased()
            case .upper: cased = text.uppercased()
            }
            if case .text(let previous, let previousStyle)? = segments.last, previousStyle == style {
                segments[segments.count - 1] = .text(previous + cased, style)
            } else {
                segments.append(.text(cased, style))
            }
        }

        private mutating func readDollarMath(_ chars: [Character], at idx: Int, style: LaTeXProseStyle) -> Int? {
            guard idx + 1 < chars.count, chars[idx + 1] != "$" else { return nil }
            var p = idx + 1
            while p < chars.count {
                if chars[p] == "\\" {
                    p += 2
                    continue
                }
                if chars[p] == "$" {
                    appendMath(String(chars[(idx + 1)..<p]), style: style)
                    return p + 1
                }
                p += 1
            }
            return nil
        }

        mutating func appendMath(_ latex: String, style: LaTeXProseStyle) {
            segments.append(.math(mathWithTextMacrosReplaced(latex), style))
        }

        mutating func appendLineBreak() {
            segments.append(.lineBreak)
        }

        mutating func appendParagraphBreak() {
            guard hasVisibleTextOnCurrentLine else { return }
            while case let .text(text, _)? = segments.last,
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                segments.removeLast()
            }
            segments.append(.lineBreak)
        }

        mutating func trimTrailingWhitespaceAndBreaks() {
            while let last = segments.last {
                switch last {
                case .lineBreak:
                    segments.removeLast()
                case let .text(text, _):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        segments.removeLast()
                    } else {
                        return
                    }
                case .math:
                    return
                }
            }
        }

        private static func readArgumentsPaddingGuardedTrailingOptionals(
            for def: LaTeXMacroDefinition,
            in chars: [Character],
            from start: Int
        ) -> (args: [String], end: Int)? {
            guard def.argCount >= 2, def.parameterText == nil else { return nil }
            var idx = start
            var args: [String] = []
            if let defaultOpt = def.defaultFirstArg {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                if let (optVal, afterOpt) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) {
                    args.append(optVal)
                    idx = afterOpt
                } else {
                    args.append(defaultOpt)
                }
            }
            var suppliedBracedCount = 0
            while args.count < def.argCount {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                guard let (value, after) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) else { break }
                args.append(value)
                suppliedBracedCount += 1
                idx = after
            }
            let trailingProbe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            guard suppliedBracedCount >= 1,
                args.count < def.argCount,
                trailingProbe >= chars.count || chars[trailingProbe] != "{"
            else {
                return nil
            }
            for paramNumber in (args.count + 1)...def.argCount {
                guard isParameterGuardedForEmpty(paramNumber, in: def.replacement) else { return nil }
            }
            while args.count < def.argCount {
                args.append("")
            }
            return (args, idx)
        }

        private static func isParameterGuardedForEmpty(_ paramNumber: Int, in replacement: String) -> Bool {
            let needle = "#\(paramNumber)"
            return replacement.contains("\\ifstrequal{\(needle)}{}{")
                || replacement.contains("\\ifblank{\(needle)}{")
                || replacement.contains("\\ifstrempty{\(needle)}{")
        }

        private static func sanitizeArguments(_ args: [String], forReplacement replacement: String) -> [String] {
            let escapeAmpersand = !hasUnwrappedAlignmentAmpersand(replacement)
            let escapeUnderscore = !replacement.contains("$") && !replacement.contains("\\(") && !replacement.contains("\\ensuremath")
            guard escapeAmpersand || escapeUnderscore else { return args }
            return args.map { arg in
                guard (escapeAmpersand && arg.contains("&")) || (escapeUnderscore && arg.contains("_")) else {
                    return arg
                }
                return sanitizeArgument(arg, escapeAmpersand: escapeAmpersand, escapeUnderscore: escapeUnderscore)
            }
        }

        private static func hasUnwrappedAlignmentAmpersand(_ replacement: String) -> Bool {
            guard replacement.contains("&") else { return false }
            let chars = Array(replacement)
            var alignmentDepth = 0
            var idx = 0
            while idx < chars.count {
                let ch = chars[idx]
                if ch == "%" {
                    while idx < chars.count && chars[idx] != "\n" { idx += 1 }
                    continue
                }
                if ch == "$" {
                    idx += 1
                    while idx < chars.count {
                        if chars[idx] == "\\" {
                            idx += 2
                            continue
                        }
                        if chars[idx] == "$" {
                            idx += 1
                            break
                        }
                        idx += 1
                    }
                    continue
                }
                if ch == "\\" {
                    if idx + 1 < chars.count && chars[idx + 1] == "(" {
                        idx += 2
                        while idx + 1 < chars.count && !(chars[idx] == "\\" && chars[idx + 1] == ")") {
                            idx += chars[idx] == "\\" ? 2 : 1
                        }
                        idx = min(chars.count, idx + 2)
                        continue
                    }
                    let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: idx)
                    if (word == "\\begin" || word == "\\end"),
                        let (envName, afterEnv) = LaTeXMacroExpander.readBracedGroup(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: afterWord))
                    {
                        if isAlignmentEnvironmentName(envName) {
                            alignmentDepth += word == "\\begin" ? 1 : -1
                            alignmentDepth = max(0, alignmentDepth)
                        }
                        idx = afterEnv
                        continue
                    }
                    idx = max(idx + 1, afterWord)
                    continue
                }
                if ch == "&" && alignmentDepth == 0 {
                    return true
                }
                idx += 1
            }
            return false
        }

        private static func isAlignmentEnvironmentName(_ name: String) -> Bool {
            name.hasPrefix("tabular") || name == "array" || name.hasPrefix("align") || name.hasPrefix("flalign")
                || name.hasSuffix("matrix") || name == "cases"
        }

        private static func sanitizeArgument(_ arg: String, escapeAmpersand: Bool, escapeUnderscore: Bool) -> String {
            let chars = Array(arg)
            var out: [Character] = []
            out.reserveCapacity(chars.count + 4)
            var alignmentDepth = 0
            var idx = 0
            while idx < chars.count {
                let ch = chars[idx]
                if ch == "\\" {
                    guard idx + 1 < chars.count else {
                        out.append(ch)
                        break
                    }
                    let next = chars[idx + 1]
                    if !next.isLetter && next != "@" {
                        if next == "(" {
                            out.append(ch)
                            out.append(next)
                            idx += 2
                            while idx < chars.count {
                                if chars[idx] == "\\" && idx + 1 < chars.count && chars[idx + 1] == ")" {
                                    out.append("\\")
                                    out.append(")")
                                    idx += 2
                                    break
                                }
                                out.append(chars[idx])
                                idx += 1
                            }
                            continue
                        }
                        out.append(ch)
                        out.append(next)
                        idx += 2
                        continue
                    }
                    let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: idx)
                    if word == "\\url" || word == "\\href" || word == "\\ensuremath" {
                        out.append(contentsOf: word)
                        let probe = LaTeXMacroExpander.skipSpaces(chars, from: afterWord)
                        if let (group, afterGroup) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) {
                            out.append(contentsOf: chars[afterWord..<probe])
                            out.append("{")
                            out.append(contentsOf: group)
                            out.append("}")
                            idx = afterGroup
                            continue
                        }
                        idx = afterWord
                        continue
                    }
                    if (word == "\\begin" || word == "\\end"),
                        let (envName, afterEnv) = LaTeXMacroExpander.readBracedGroup(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: afterWord))
                    {
                        if isAlignmentEnvironmentName(envName) {
                            alignmentDepth += word == "\\begin" ? 1 : -1
                            alignmentDepth = max(0, alignmentDepth)
                        }
                        out.append(contentsOf: chars[idx..<afterEnv])
                        idx = afterEnv
                        continue
                    }
                    out.append(contentsOf: word)
                    idx = afterWord
                    continue
                }
                if ch == "$" {
                    out.append(ch)
                    idx += 1
                    while idx < chars.count {
                        let mathCh = chars[idx]
                        out.append(mathCh)
                        if mathCh == "\\" && idx + 1 < chars.count {
                            idx += 1
                            out.append(chars[idx])
                            idx += 1
                            continue
                        }
                        idx += 1
                        if mathCh == "$" { break }
                    }
                    continue
                }
                if matchPrefix("http://", chars, at: idx) || matchPrefix("https://", chars, at: idx) || matchPrefix("www.", chars, at: idx) {
                    while idx < chars.count && isBareURLCharacter(chars[idx]) {
                        out.append(chars[idx])
                        idx += 1
                    }
                    continue
                }
                if ch == "&" && escapeAmpersand && alignmentDepth == 0 {
                    out.append("\\")
                    out.append("&")
                    idx += 1
                    continue
                }
                if ch == "_" && escapeUnderscore && alignmentDepth == 0 {
                    out.append("\\")
                    out.append("_")
                    idx += 1
                    continue
                }
                out.append(ch)
                idx += 1
            }
            return String(out)
        }

        private static func matchPrefix(_ prefix: String, _ chars: [Character], at idx: Int) -> Bool {
            let p = Array(prefix)
            guard idx + p.count <= chars.count else { return false }
            return Array(chars[idx..<(idx + p.count)]) == p
        }

        private static func isBareURLCharacter(_ ch: Character) -> Bool {
            !ch.isWhitespace && ch != "}" && ch != "{" && ch != "\\" && ch != "]" && ch != ">" && ch != "$" && ch != "%"
        }
    }
}
