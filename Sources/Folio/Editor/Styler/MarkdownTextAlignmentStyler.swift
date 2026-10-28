import AppKit

extension MarkdownLiveStyler {

    /// Applies the editor-wide alignment to prose lines only (paragraphs, list items, and
    /// blockquotes). Headings, code, math, and tables keep their own alignment.
    static func applyProseAlignment(
        _ alignment: NSTextAlignment,
        to storage: NSTextStorage,
        lineRecords: [Int: LineRecord],
        proseLineKinds: [Int: ProseLineKind]
    ) {
        guard alignment != .natural && alignment != .left else { return }
        for lineNumber in proseLineKinds.keys {
            guard let record = lineRecords[lineNumber], record.lineRange.length > 0,
                let style = storage.attribute(.paragraphStyle, at: record.lineRange.location, effectiveRange: nil) as? NSParagraphStyle,
                let mutable = style.mutableCopy() as? NSMutableParagraphStyle
            else { continue }
            mutable.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: mutable, range: record.lineRange)
        }
    }
}
