import Foundation

extension LaTeXProseMacroExpander.Renderer {
    /// Deepest nesting of text macros inside math inside text macros.
    private static let maxMathNesting = 3

    /// Replaces calls to text-mode user macros in `latex` with math font commands. A macro such
    /// as clqr's `\VAR{x}`, which is `\text{{\fontshape{it}\selectfont x}}`, would otherwise show
    /// its font commands as text inside `$\widehat{..}$`. Only calls whose body uses a text-mode
    /// command and that render as plain styled text are replaced. Math macros stay for the math
    /// renderer.
    func mathWithTextMacrosReplaced(_ latex: String) -> String {
        guard mathNesting < Self.maxMathNesting, latex.contains("\\") || latex.contains("%") else { return latex }
        let chars = Array(LaTeXLiveStyler.maskedComments(latex))
        var out = ""
        var idx = 0
        while idx < chars.count {
            guard chars[idx] == "\\", idx + 1 < chars.count, chars[idx + 1].isLetter else {
                let end = chars[idx] == "\\" ? min(chars.count, idx + 2) : idx + 1
                out += String(chars[idx..<end])
                idx = end
                continue
            }
            let (word, afterWord) = LaTeXMacroExpander.readControlWord(chars, at: idx)
            let name = String(word.dropFirst())
            if let replacement = textMacroReplacement(chars, at: idx, name: name) {
                out += replacement.text
                idx = replacement.end
            } else if let shape = Self.textBoxes[name], let (content, end) = Self.boxContent(chars, after: afterWord, shape: shape) {
                // A box draws its content as text; its offsets and sizes are layout.
                let inner = mathWithTextMacrosReplaced(content).trimmingCharacters(in: .whitespaces)
                out += inner.contains("\\") || inner.contains("{") ? "{\(inner)}" : "\\text{\(inner)}"
                idx = end
            } else if let entry = LaTeXLayoutCommands.entries[name], entry.kind == .declaration || name == "hspace" || name == "vspace" {
                // Text font switches and spacing are not valid math.
                idx = LaTeXLayoutLine.readCommand(chars, at: idx, macros: [:]).end
            } else {
                out += word
                idx = afterWord
            }
        }
        return out
    }

    /// Boxes inside math whose content Folio draws, with the `{..}` and `[..]` arguments before it.
    private static let textBoxes: [String: (braces: Int, brackets: Int)] = [
        "raisebox": (1, 2), "makebox": (0, 2), "mbox": (0, 0), "hbox": (0, 0), "fbox": (0, 0)
    ]

    private static func boxContent(_ chars: [Character], after start: Int, shape: (braces: Int, brackets: Int)) -> (String, Int)? {
        var idx = start
        for _ in 0..<shape.braces {
            guard let (_, after) = LaTeXMacroExpander.readBracedGroup(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: idx)) else { return nil }
            idx = after
        }
        for _ in 0..<shape.brackets {
            guard let (_, after) = LaTeXMacroExpander.readBracketGroup(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: idx)) else { break }
            idx = after
        }
        return LaTeXMacroExpander.readBracedGroup(chars, at: LaTeXMacroExpander.skipSpaces(chars, from: idx))
    }

    private func textMacroReplacement(_ chars: [Character], at idx: Int, name: String) -> (text: String, end: Int)? {
        guard let (def, _) = LaTeXProseMacroExpander.definition(forCall: name, in: macros), Self.usesTextMode(def.replacement) else {
            return nil
        }
        var nested = LaTeXProseMacroExpander.Renderer(macros: macros, limits: limits, mathNesting: mathNesting + 1)
        guard let end = nested.expandUserMacro(chars, at: idx, style: nil, depth: 0) else { return nil }
        var text = ""
        for segment in nested.segments {
            switch segment {
            case let .text(value, style):
                text += Self.mathText(value, style: style)
            case let .math(inner, _):
                text += "{\(inner)}"
            case .lineBreak:
                return nil
            }
        }
        return text.isEmpty ? nil : ("{\(text)}", end)
    }

    private static func usesTextMode(_ body: String) -> Bool {
        ["\\text", "\\mbox", "\\selectfont", "\\fontshape", "\\fontseries", "\\fontfamily", "\\itshape", "\\bfseries", "\\ttfamily", "\\sffamily"]
            .contains { body.contains($0) }
    }

    /// `text` in the math font command closest to `style`, with spaces kept as `\ `.
    private static func mathText(_ text: String, style: LaTeXProseStyle) -> String {
        let command: String
        if style.monospace {
            command = "\\mathtt"
        } else if style.bold && style.italic {
            command = "\\mathbfit"
        } else if style.bold {
            command = "\\mathbf"
        } else if style.italic {
            command = "\\mathit"
        } else if style.sans {
            command = "\\mathsf"
        } else {
            command = "\\mathrm"
        }
        var escaped = ""
        for ch in text.trimmingCharacters(in: .whitespaces) {
            switch ch {
            case " ": escaped += "\\ "
            case "#", "$", "%", "&", "_", "{", "}": escaped += "\\\(ch)"
            case "\\": escaped += "\\backslash "
            default: escaped.append(ch)
            }
        }
        return escaped.isEmpty ? "" : "\(command){\(escaped)}"
    }
}
