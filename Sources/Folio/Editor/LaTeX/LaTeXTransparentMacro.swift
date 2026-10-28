import Foundation

/// How Folio shows a call to a user macro whose body is layout that it cannot render, such as
/// clqr's `\IT`, which measures its arguments with `\settowidth` and `\loop`. The call is drawn
/// "transparently": the macro name and the argument braces are hidden as syntax, each argument's
/// content is styled in place, and a separator is drawn before each argument after the first.
struct LaTeXTransparentMacro: Equatable, Sendable {
    /// Segments to draw before argument `n + 1`, keyed by the 0-based argument index `n` (1 or
    /// more). A missing key means the default separator.
    let separators: [Int: [LaTeXProseSegment]]

    /// The default separator between arguments on one line: an em space.
    static let defaultSeparator: [LaTeXProseSegment] = [.text("\u{2003}", LaTeXProseStyle())]

    /// Analyzes `def`. Returns nil unless the macro takes arguments, its body uses each of them,
    /// and the body cannot be rendered as prose even with plain arguments. A body that renders is
    /// not layout: a call that fails because of its arguments keeps its source.
    static func analyze(_ def: LaTeXMacroDefinition, macros: [String: LaTeXMacroDefinition]) -> LaTeXTransparentMacro? {
        let argumentCount = def.parameterText?.delimiters.count ?? def.argCount
        guard argumentCount > 0, !def.isEnvironment, def.operatorText == nil else { return nil }
        let body = def.replacement
        for number in 1...argumentCount where !body.contains("#\(number)") {
            return nil
        }
        let plainArguments = Array(repeating: "x", count: argumentCount)
        let plainBody = LaTeXMacroExpander.substituteArguments(plainArguments, into: body)
        guard LaTeXProseMacroExpander.render(plainBody, macros: macros) == nil else { return nil }
        var separators: [Int: [LaTeXProseSegment]] = [:]
        if argumentCount > 1 {
            for number in 2...argumentCount {
                if let hint = separatorHint(before: number, in: body, macros: macros) {
                    separators[number - 1] = hint
                }
            }
        }
        return LaTeXTransparentMacro(separators: separators)
    }

    /// The rendering of the macro without arguments that the body puts right before its last
    /// `#number`, as clqr's `\startexplanation#2` draws "▷". Nil when there is none.
    private static func separatorHint(before number: Int, in body: String, macros: [String: LaTeXMacroDefinition]) -> [LaTeXProseSegment]? {
        guard let marker = body.range(of: "#\(number)", options: .backwards) else { return nil }
        let before = Array(body[..<marker.lowerBound])
        var end = before.count
        while end > 0 && before[end - 1].isWhitespace { end -= 1 }
        var start = end
        while start > 0 && before[start - 1].isLetter { start -= 1 }
        guard start > 0, start < end, before[start - 1] == "\\" else { return nil }
        let name = String(before[start..<end])
        guard let def = macros["\\\(name)"], def.argCount == 0, def.parameterText == nil,
            let segments = LaTeXProseMacroExpander.render(def.replacement, macros: macros),
            segments.contains(where: Self.isVisible)
        else { return nil }
        return segments + [.text(" ", LaTeXProseStyle())]
    }

    private static func isVisible(_ segment: LaTeXProseSegment) -> Bool {
        switch segment {
        case .text(let text, _): return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .math: return true
        case .lineBreak: return false
        }
    }
}
