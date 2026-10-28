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
        guard let end = renderer.expandUserMacro(chars, at: 0, style: nil, depth: 0) else { return nil }
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

        init(macros: [String: LaTeXMacroDefinition], limits: Limits) {
            self.macros = macros
            self.limits = limits
            expandedBudget = limits.maxExpandedCharacters
        }

        /// Expands the user macro call at `chars[start]` and renders its body. With a nil
        /// `style`, the body starts from the default style. Returns the index after the call.
        mutating func expandUserMacro(
            _ chars: [Character],
            at start: Int,
            style: LaTeXProseStyle?,
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
            guard let (args, afterArgs) = LaTeXMacroExpander.readArguments(for: def, in: chars, from: end) else { return nil }
            end = afterArgs
            if def.argCount == 0 && def.parameterText == nil && style == nil
                && end + 1 < chars.count && chars[end] == "{" && chars[end + 1] == "}"
            {
                end += 2
            }
            let body = LaTeXMacroExpander.substituteArguments(args, into: def.replacement)
            expandedBudget -= body.count
            guard expandedBudget >= 0 else { return nil }
            var bodyStyle = style ?? LaTeXProseStyle()
            guard render(Array(body), style: &bodyStyle, depth: depth + 1) else { return nil }
            return end
        }

        /// Renders `chars` with `style`. Declarations change `style`, so they last until the
        /// enclosing group ends, as in TeX.
        mutating func render(_ chars: [Character], style: inout LaTeXProseStyle, depth: Int) -> Bool {
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
            case "}", "#", "&", "^", "_":
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
                emit(" ", style: style)
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
                    segments.append(.math(String(chars[(idx + 1)..<p]), style))
                    return p + 1
                }
                p += 1
            }
            return nil
        }

        mutating func appendMath(_ latex: String, style: LaTeXProseStyle) {
            segments.append(.math(latex, style))
        }

        mutating func appendLineBreak() {
            segments.append(.lineBreak)
        }
    }
}
