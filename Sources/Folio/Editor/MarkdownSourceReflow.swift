import Foundation
import FolioEngineFFI

/// Hard-wraps Markdown paragraph source to a column width using the shared `folio_engine` reflow.
public enum MarkdownSourceReflow {
    public static let defaultWidth = 80
    public static let widthOptions = [0, 72, 80, 100, 120]

    public struct ParagraphEdit: Equatable {
        /// Source range of the paragraph lines, excluding the newline after the last line.
        public let range: NSRange
        public let replacement: String
        /// 1-based, inclusive line span of the paragraph.
        public let lines: ClosedRange<Int>
    }

    /// Returns the rewrap of the paragraph that contains the 1-based `line`, or `nil` when the
    /// line is not in a paragraph.
    public static func reflowParagraph(in text: String, line: Int, width: Int) -> ParagraphEdit? {
        guard width > 0, line > 0 else { return nil }
        return text.withCString { ptr -> ParagraphEdit? in
            let result = ot_engine_reflow_paragraph_at_line(ptr, UInt32(line), UInt32(width))
            defer { ot_engine_free_paragraph_reflow(result) }
            guard result.found, let replacementPtr = result.replacement else { return nil }
            let lines = Int(result.start_line)...Int(result.end_line)
            guard let range = sourceRange(of: lines, in: text as NSString) else { return nil }
            return ParagraphEdit(range: range, replacement: String(cString: replacementPtr), lines: lines)
        }
    }

    /// Rewraps every paragraph in the document.
    public static func reflowDocument(_ text: String, width: Int) -> String {
        guard width > 0 else { return text }
        return text.withCString { ptr -> String in
            guard let out = ot_engine_reflow_markdown(ptr, UInt32(width)) else { return text }
            defer { ot_engine_free_string(out) }
            return String(cString: out)
        }
    }

    /// 1-based, inclusive line spans of all CommonMark paragraphs.
    public static func paragraphLineSpans(in text: String) -> [ClosedRange<Int>] {
        MarkdownLiveStyler.parseSpecAST(text).blocks
            .filter { $0.kind == 8 && $0.startLine > 0 && $0.endLine >= $0.startLine }
            .map { $0.startLine...$0.endLine }
    }

    /// 1-based line number that contains the UTF-16 `location`.
    public static func lineNumber(at location: Int, in text: NSString) -> Int {
        let end = max(0, min(location, text.length))
        var line = 1
        var index = 0
        while index < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: end - index))
            guard found.location != NSNotFound else { break }
            line += 1
            index = found.location + 1
        }
        return line
    }

    /// Source range of the 1-based `lines`, excluding the newline after the last line.
    public static func sourceRange(of lines: ClosedRange<Int>, in text: NSString) -> NSRange? {
        var line = 1
        var index = 0
        var start: Int? = lines.lowerBound == 1 ? 0 : nil
        while index <= text.length {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: index, length: text.length - index))
            let lineEnd = found.location == NSNotFound ? text.length : found.location
            if line == lines.upperBound, let s = start {
                return NSRange(location: s, length: lineEnd - s)
            }
            guard found.location != NSNotFound else { return nil }
            index = found.location + 1
            line += 1
            if line == lines.lowerBound {
                start = index
            }
        }
        return nil
    }

    /// Maps a location inside `oldRange` of `oldText` to the same non-whitespace character
    /// position in `replacement`. Reflow changes only whitespace and container prefixes.
    public static func mapLocation(_ location: Int, in oldText: NSString, oldRange: NSRange, to replacement: NSString) -> Int {
        let clamped = max(oldRange.location, min(location, NSMaxRange(oldRange)))
        var visible = 0
        for i in oldRange.location..<clamped where !isWhitespace(oldText.character(at: i)) {
            visible += 1
        }
        guard visible > 0 else { return 0 }
        var seen = 0
        for i in 0..<replacement.length where !isWhitespace(replacement.character(at: i)) {
            seen += 1
            if seen == visible {
                return i + 1
            }
        }
        return replacement.length
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 13
    }
}
