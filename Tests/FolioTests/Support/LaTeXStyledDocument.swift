import AppKit
@testable import Folio

/// Styles a LaTeX document from a string, as the editor does, and returns its render dump.
@MainActor
enum LaTeXStyledDocument {
    /// `cursorLine` is zero-based; nil puts the cursor at the end of the document.
    static func style(_ text: String, cursorLine: Int? = nil, storage: NSTextStorage? = nil) -> (storage: NSTextStorage, analysis: MarkdownDocumentAnalysis) {
        let target = storage ?? NSTextStorage(string: text)
        if target.string != text {
            // Replace only the changed middle, as an edit does, so the rest keeps its styling.
            let old = target.string as NSString
            let new = text as NSString
            var prefix = 0
            while prefix < min(old.length, new.length) && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < min(old.length, new.length) - prefix
                && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix)
            {
                suffix += 1
            }
            target.replaceCharacters(
                in: NSRange(location: prefix, length: old.length - prefix - suffix),
                with: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
            )
        }
        let lines = text.components(separatedBy: "\n")
        let location = cursorLine.map { line in lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 } } ?? target.length
        let analysis = LaTeXLiveStyler.applyStyles(
            to: target,
            theme: .daylight,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: min(location, target.length), length: 0),
            containerWidth: 900
        )
        return (target, analysis)
    }

    /// The dump lines of `text`, without the `NNN| ` prefixes and block list.
    static func renderedLines(_ text: String, cursorLine: Int? = nil) -> [String] {
        let (storage, analysis) = style(text, cursorLine: cursorLine)
        return LaTeXRenderDump.dump(storage, decorations: analysis.decorations)
            .components(separatedBy: "\n")
            .prefix { $0 != "blocks:" }
            .filter { !$0.isEmpty }
            .map { String($0.dropFirst(5)) }
    }

    /// A document with `preamble` definitions and `body` between `\begin{document}` and
    /// `\end{document}`. The body starts on line `bodyStartLine`.
    static func document(preamble: String, body: String) -> String {
        "\\documentclass{article}\n\(preamble)\n\\begin{document}\n\(body)\n\\end{document}\n"
    }

    static func bodyStartLine(preamble: String) -> Int {
        preamble.components(separatedBy: "\n").count + 2
    }
}
