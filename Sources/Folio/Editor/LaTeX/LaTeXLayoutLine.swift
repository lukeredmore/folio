import Foundation

/// What one line of LaTeX does to the layout: the group and font changes that last past the
/// line, and whether the line prints anything.
struct LaTeXLayoutLine: Equatable {
    /// Changes that last after the line, in source order.
    var effects: [LaTeXFlowEffect] = []
    /// True when the line holds only commands that print nothing, environment boundaries,
    /// braces, and `\\`. Such a line folds like other syntax.
    var isLayoutOnly = false
    /// True when the line draws a `\rule` with a nonzero size or an `\hrule`.
    var drawsRule = false

    /// Analyzes `code`, a line without its `%` comment. `\begin` lines of environments outside
    /// `wrappers` count as content, because Folio styles those environments as blocks.
    static func analyze(
        _ code: String,
        macros: [String: LaTeXMacroDefinition],
        wrappers: Set<String> = LaTeXLayoutCommands.flowWrapperEnvironments
    ) -> LaTeXLayoutLine {
        analyze(code, macros: macros, wrappers: wrappers, nesting: 0)
    }

    /// Most user macros that a layout check expands inside one another.
    private static let maxNesting = 4

    private static func analyze(
        _ code: String,
        macros: [String: LaTeXMacroDefinition],
        wrappers: Set<String>,
        nesting: Int
    ) -> LaTeXLayoutLine {
        guard code.contains(where: { $0 == "\\" || $0 == "{" || $0 == "}" }) else { return LaTeXLayoutLine() }
        var reader = Reader(chars: Array(code), macros: macros, wrappers: wrappers)
        reader.nesting = nesting
        reader.run()
        var result = LaTeXLayoutLine()
        result.effects = reader.groups[0]
        for group in reader.groups.dropFirst() {
            result.effects.append(.openGroup)
            result.effects += group
        }
        result.isLayoutOnly = !reader.sawContent && reader.sawToken
        result.drawsRule = reader.drawsRule
        return result
    }

    /// Reads the command at `chars[start]`, a backslash. Returns where it and its arguments end,
    /// the effects it makes, and whether it prints nothing (a layout command or a definition).
    static func readCommand(
        _ chars: [Character],
        at start: Int,
        macros: [String: LaTeXMacroDefinition]
    ) -> (end: Int, effects: [LaTeXFlowEffect], isLayout: Bool) {
        var reader = Reader(chars: chars, macros: macros, wrappers: LaTeXLayoutCommands.flowWrapperEnvironments)
        reader.idx = start
        reader.readCommand()
        return (reader.idx, reader.groups[0], !reader.sawContent)
    }

    private struct Reader {
        let chars: [Character]
        let macros: [String: LaTeXMacroDefinition]
        let wrappers: Set<String>
        /// Effects of the line's top level, then of each group that the line opens and leaves open.
        var groups: [[LaTeXFlowEffect]] = [[]]
        var sawContent = false
        var sawToken = false
        var drawsRule = false
        var idx = 0
        var nesting = 0

        init(chars: [Character], macros: [String: LaTeXMacroDefinition], wrappers: Set<String>) {
            self.chars = chars
            self.macros = macros
            self.wrappers = wrappers
        }

        mutating func run() {
            while idx < chars.count {
                let ch = chars[idx]
                if ch == "%" { return }
                if ch.isWhitespace {
                    idx += 1
                    continue
                }
                sawToken = true
                switch ch {
                case "{":
                    groups.append([])
                    idx += 1
                case "}":
                    if groups.count > 1 {
                        groups.removeLast()
                    } else {
                        groups[0].append(.closeGroup)
                    }
                    idx += 1
                case "\\":
                    readCommand()
                default:
                    sawContent = true
                    idx += 1
                }
            }
        }

        private mutating func record(_ effect: LaTeXFlowEffect) {
            groups[groups.count - 1].append(effect)
        }

        mutating func readCommand() {
            guard idx + 1 < chars.count else {
                sawContent = true
                idx += 1
                return
            }
            let next = chars[idx + 1]
            guard next.isLetter || next == "@" else {
                readControlSymbol(next)
                return
            }
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            let name = String(word.dropFirst())
            idx = after
            if name == "begin" || name == "end" {
                readEnvironment(isBegin: name == "begin")
            } else if let entry = LaTeXLayoutCommands.entries[name] {
                readLayoutCommand(name, entry)
            } else if LaTeXLayoutCommands.definitionCommands.contains(name) {
                if !skipDefinition(name) { sawContent = true }
            } else if isInvisibleUserMacro(name) {
                if idx + 1 < chars.count && chars[idx] == "{" && chars[idx + 1] == "}" { idx += 2 }
            } else if let end = registerAssignmentEnd(name, from: idx) {
                idx = end
            } else {
                sawContent = true
            }
        }

        private mutating func readControlSymbol(_ symbol: Character) {
            idx += 2
            switch symbol {
            case "\\":
                if idx < chars.count && chars[idx] == "*" { idx += 1 }
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                if let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) { idx = after }
            case "/", "@", "-", "!", ",", ";", ":", " ":
                break
            default:
                sawContent = true
            }
        }

        private mutating func readEnvironment(isBegin: Bool) {
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            guard let (rawName, after) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) else {
                sawContent = true
                return
            }
            let name = rawName.trimmingCharacters(in: .whitespaces)
            idx = after
            guard isBegin else {
                record(.endEnvironment(name))
                return
            }
            record(.beginEnvironment(name))
            // `minipage` takes `[pos][height][inner]{width}`; `multicols` takes `{columns}[..]`.
            if name == "minipage" {
                idx = skipBrackets(from: idx, limit: 3)
                idx = skipBraces(from: idx, limit: 1)
            } else if name.hasPrefix("multicols") {
                idx = skipBraces(from: idx, limit: 1)
                idx = skipBrackets(from: idx, limit: 1)
            } else if !wrappers.contains(name) {
                sawContent = true
            }
        }

        private mutating func readLayoutCommand(_ name: String, _ entry: LaTeXLayoutCommands.Entry) {
            if idx < chars.count && chars[idx] == "*" { idx += 1 }
            idx = skipBrackets(from: idx, limit: entry.brackets)
            var arguments: [String] = []
            for _ in 0..<entry.braces {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                guard probe < chars.count, chars[probe] != "}", let (value, after) = LaTeXMacroExpander.readMacroArgument(chars, at: probe) else {
                    sawContent = true
                    return
                }
                arguments.append(value)
                idx = after
            }
            idx = skipBrackets(from: idx, limit: entry.trailingBrackets)
            if entry.dimension {
                idx = LaTeXLayoutLine.skipValue(chars, from: idx)
            }
            switch entry.kind {
            case .invisible:
                break
            case .declaration:
                if let declaration = LaTeXLayoutCommands.declaration(named: name, arguments: arguments) {
                    record(.declaration(declaration))
                }
            case .rule:
                let sizes = arguments.map { LaTeXLength.parse($0)?.resolvedPoints(baseSize: 10) ?? 1 }
                if name == "hrule" || !sizes.contains(0) { drawsRule = true }
            }
        }

        /// Skips a definition after its command name. Returns false when it is malformed.
        private mutating func skipDefinition(_ name: String) -> Bool {
            switch name {
            case "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand":
                if idx < chars.count && chars[idx] == "*" { idx += 1 }
                guard skipControlSequenceArgument() else { return false }
                idx = skipBrackets(from: idx, limit: 2)
                return skipRequiredBraces(1)
            case "newenvironment", "renewenvironment":
                if idx < chars.count && chars[idx] == "*" { idx += 1 }
                guard skipRequiredBraces(1) else { return false }
                idx = skipBrackets(from: idx, limit: 2)
                return skipRequiredBraces(2)
            case "def", "gdef", "edef", "xdef":
                guard skipControlSequenceArgument() else { return false }
                while idx < chars.count && chars[idx] != "{" {
                    if chars[idx] == "}" || chars[idx] == "%" { return false }
                    idx += 1
                }
                return skipRequiredBraces(1)
            case "let":
                guard skipControlSequenceArgument() else { return false }
                idx = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                if idx < chars.count && chars[idx] == "=" { idx = LaTeXMacroExpander.skipSpaces(chars, from: idx + 1) }
                guard idx < chars.count else { return false }
                idx = chars[idx] == "\\" ? LaTeXMacroExpander.readControlWord(chars, at: idx).1 : idx + 1
                return true
            case "advance", "multiply", "divide":
                guard skipControlSequenceArgument() else { return false }
                idx = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                if matches("by", at: idx) { idx += 2 }
                idx = LaTeXLayoutLine.skipValue(chars, from: idx)
                return true
            case "global":
                return true
            default:
                return skipControlSequenceArgument()
            }
        }

        /// Skips `\name` or `{\name}`.
        private mutating func skipControlSequenceArgument() -> Bool {
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
            guard let (_, after) = LaTeXMacroExpander.readMacroNameArg(chars, at: probe) else { return false }
            idx = after
            return true
        }

        private mutating func skipRequiredBraces(_ count: Int) -> Bool {
            for _ in 0..<count {
                var probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                while probe < chars.count && chars[probe] == "%" {
                    while probe < chars.count && chars[probe] != "\n" { probe += 1 }
                    probe = LaTeXMacroExpander.skipSpaces(chars, from: probe)
                }
                guard let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) else { return false }
                idx = after
            }
            return true
        }

        private func skipBrackets(from start: Int, limit: Int) -> Int {
            var position = start
            for _ in 0..<limit {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: position)
                guard let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: probe) else { break }
                position = after
            }
            return position
        }

        private func skipBraces(from start: Int, limit: Int) -> Int {
            var position = start
            for _ in 0..<limit {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: position)
                guard let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) else { break }
                position = after
            }
            return position
        }

        /// A user macro without arguments whose expansion prints nothing, such as a hook that a
        /// paper-size file may redefine to `\clearpage`.
        private func isInvisibleUserMacro(_ name: String) -> Bool {
            guard let def = macros["\\\(name)"], def.argCount == 0, def.parameterText == nil, !def.isEnvironment,
                def.operatorText == nil
            else { return false }
            return LaTeXLayoutLine.printsNothing(def.replacement, macros: macros, nesting: nesting + 1)
        }

        /// The end of `=value` after a register name, as in `\ITtab=3em`, or nil.
        private func registerAssignmentEnd(_ name: String, from start: Int) -> Int? {
            let probe = LaTeXMacroExpander.skipSpaces(chars, from: start)
            if probe < chars.count, chars[probe] == "=" {
                return LaTeXLayoutLine.skipValue(chars, from: probe + 1)
            }
            // A known length takes its value without `=`, as in `\arraycolsep0pt`.
            guard LaTeXLayoutCommands.lengthRegisters.contains(name) else { return nil }
            let end = LaTeXLayoutLine.skipValue(chars, from: start)
            return end > start ? end : nil
        }

        private func matches(_ text: String, at position: Int) -> Bool {
            let pattern = Array(text)
            guard position + pattern.count <= chars.count else { return false }
            return Array(chars[position..<(position + pattern.count)]) == pattern
        }
    }

    /// True when the macro body `body` prints nothing: it renders to blank text, or it holds only
    /// layout commands.
    static func printsNothing(_ body: String, macros: [String: LaTeXMacroDefinition], nesting: Int = 0) -> Bool {
        guard nesting <= maxNesting else { return false }
        if let segments = LaTeXProseMacroExpander.render(body, macros: macros) {
            return segments.allSatisfy {
                if case .text(let text, _) = $0 { return text.trimmingCharacters(in: .whitespaces).isEmpty }
                return false
            }
        }
        let code = LaTeXLiveStyler.maskedComments(body)
        return analyze(code, macros: macros, wrappers: LaTeXLayoutCommands.flowWrapperEnvironments, nesting: nesting).isLayoutOnly
    }

    /// Skips a TeX number, dimension, or register value: `-1.5mm`, `4`, `\value{page}`, or
    /// `\ITtab`.
    static func skipValue(_ chars: [Character], from start: Int) -> Int {
        var idx = LaTeXMacroExpander.skipSpaces(chars, from: start)
        if idx < chars.count && (chars[idx] == "-" || chars[idx] == "+") { idx += 1 }
        if idx < chars.count && chars[idx] == "\\" {
            let (word, after) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            idx = after
            if word == "\\value" || word == "\\the" {
                let probe = LaTeXMacroExpander.skipSpaces(chars, from: idx)
                if let (_, afterGroup) = LaTeXMacroExpander.readBracedGroup(chars, at: probe) {
                    idx = afterGroup
                } else if probe < chars.count && chars[probe] == "\\" {
                    idx = LaTeXMacroExpander.readControlWord(chars, at: probe).1
                }
            }
            return idx
        }
        let numberStart = idx
        while idx < chars.count && (chars[idx].isNumber || chars[idx] == "." || chars[idx] == ",") { idx += 1 }
        guard idx > numberStart else { return start }
        let unitStart = LaTeXMacroExpander.skipSpaces(chars, from: idx)
        var unitEnd = unitStart
        while unitEnd < chars.count && chars[unitEnd].isLetter && unitEnd - unitStart < 2 { unitEnd += 1 }
        let units: Set<String> = ["pt", "mm", "cm", "in", "em", "ex", "bp", "pc", "dd", "cc", "sp", "mu"]
        if unitEnd - unitStart == 2, units.contains(String(chars[unitStart..<unitEnd])) {
            idx = unitEnd
        }
        return idx
    }
}
