import Foundation

extension LaTeXBlockStyleCache {
    /// What styling a block reads from the document index besides values that `StyleConfig`
    /// and the macros hold: labels, numbering, citations, inputs, and the preamble. A session is
    /// reused only when these are equal, so a block does not keep a stale number or target.
    struct DocumentFacts: Equatable {
        var labels: [String: LaTeXLabelTarget]
        /// Section, equation, theorem, figure, and table numbers in document order.
        var numbering: [String]
        var bibEntries: [String: BibTeXEntry]
        var inputURLs: [String: URL]
        var preambleSummary: [String]
        var bodyStart: Int?

        init(_ index: LaTeXDocumentIndex) {
            labels = index.labels
            numbering =
                Self.ordered(index.lineSectionNumbers) { "\($0.level) \($0.number) \($0.starred)" }
                + Self.ordered(index.blockEquationNumbers) { "eq \($0)" }
                + Self.ordered(index.blockTheoremHeaders) { "\($0.header) \($0.isProof)" }
                + Self.ordered(index.blockFigureNumbers) { "fig \($0)" }
                + Self.ordered(index.blockTableNumbers) { "tab \($0)" }
            bibEntries = index.bibEntries
            inputURLs = index.inputURLs
            preambleSummary = [index.preambleSummaryTitle, index.preambleSummarySubtitle]
            bodyStart = index.preambleRange.map { NSMaxRange($0) }
        }

        /// The facts with their locations moved from the old text to the new text, so they
        /// compare with the facts of the new text. Nil when a location is in the changed text.
        func moved(by diff: DiffWindow) -> DocumentFacts? {
            var moved = self
            for (key, label) in labels {
                guard let location = diff.newLocation(ofOld: label.characterLocation) else { return nil }
                moved.labels[key] = LaTeXLabelTarget(
                    key: label.key, kind: label.kind, number: label.number, title: label.title, characterLocation: location)
            }
            if let bodyStart {
                guard let location = diff.newLocation(ofOld: bodyStart) else { return nil }
                moved.bodyStart = location
            }
            return moved
        }

        private static func ordered<Value>(_ values: [Int: Value], _ describe: (Value) -> String) -> [String] {
            values.sorted { $0.key < $1.key }.map { describe($0.value) }
        }
    }
}
