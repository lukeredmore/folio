import AppKit
@testable import Folio

/// Checks that the editor's styling equals a full restyle of the same text, selection, and
/// settings. A restyle that touched too little of the document leaves stale attributes,
/// decorations, or headings, and the first difference is reported.
@MainActor
enum RestyleEquivalenceOracle {
    /// Nil when the editor matches a full restyle, else a description of the first difference.
    static func firstMismatch(in harness: EditorHarness) -> String? {
        let textView = harness.textView
        guard let storage = textView.textStorage else { return "the text view has no text storage" }
        let reference = NSTextStorage(string: storage.string)
        let expected = MarkdownLiveStyler.applyStyles(
            to: reference,
            parameters: harness.coordinator.styleParameters(for: textView),
            selectedRange: textView.selectedRange()
        )
        if let difference = firstAttributeDifference(actual: storage, expected: reference) {
            return difference
        }
        if let difference = firstDifference(
            "decoration",
            actual: textView.lineDecorations,
            expected: expected.decorations,
            text: storage.string
        ) {
            return difference
        }
        return firstDifference(
            "heading",
            actual: harness.viewModel.headings,
            expected: expected.headings,
            text: storage.string
        )
    }

    /// Compares attribute runs by longest effective range, so run fragmentation does not count.
    static func firstAttributeDifference(actual: NSAttributedString, expected: NSAttributedString) -> String? {
        guard actual.string == expected.string else { return "the reference text differs from the editor text" }
        let full = NSRange(location: 0, length: actual.length)
        var location = 0
        while location < full.length {
            var actualRun = NSRange()
            var expectedRun = NSRange()
            let actualAttributes = actual.attributes(at: location, longestEffectiveRange: &actualRun, in: full)
            let expectedAttributes = expected.attributes(at: location, longestEffectiveRange: &expectedRun, in: full)
            let end = min(NSMaxRange(actualRun), NSMaxRange(expectedRun))
            if !NSDictionary(dictionary: actualAttributes).isEqual(to: expectedAttributes) {
                let keys = Set(actualAttributes.keys).union(expectedAttributes.keys).sorted { $0.rawValue < $1.rawValue }
                let key = keys.first { !isEqual(actualAttributes[$0], expectedAttributes[$0]) }
                let range = NSRange(location: location, length: end - location)
                return """
                attribute \(key?.rawValue ?? "?") differs in \(describe(range, in: actual.string)): \
                editor has \(describe(key.flatMap { actualAttributes[$0] })), \
                full restyle has \(describe(key.flatMap { expectedAttributes[$0] }))
                """
            }
            location = end
        }
        return nil
    }

    private static func firstDifference<Element: Equatable>(
        _ name: String,
        actual: [Element],
        expected: [Element],
        text: String
    ) -> String? {
        guard actual != expected else { return nil }
        let index = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(actual.count, expected.count)
        let actualItem = index < actual.count ? String(describing: actual[index]) : "nothing"
        let expectedItem = index < expected.count ? String(describing: expected[index]) : "nothing"
        return """
        \(name) \(index) differs (editor has \(actual.count), full restyle has \(expected.count)): \
        editor has \(actualItem), full restyle has \(expectedItem)
        """
    }

    private static func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return (lhs as AnyObject).isEqual(rhs as AnyObject)
        default: return false
        }
    }

    private static func describe(_ value: Any?) -> String {
        value.map { String(describing: $0) } ?? "nothing"
    }

    /// `location..<end` with the one-based line number and the text of that line.
    private static func describe(_ range: NSRange, in text: String) -> String {
        let nsText = text as NSString
        let prefix = nsText.substring(to: range.location)
        let line = prefix.components(separatedBy: "\n").count
        let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let lineText = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
        return "\(range.location)..<\(NSMaxRange(range)) (line \(line): \(lineText.debugDescription))"
    }
}
