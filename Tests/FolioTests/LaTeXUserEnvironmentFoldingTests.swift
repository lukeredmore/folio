import AppKit
import XCTest
@testable import Folio

/// Lines that only open or close a `\newenvironment` environment, or only hold `\index`
/// entries, fold like other syntax; the content between them stays visible.
final class LaTeXUserEnvironmentFoldingTests: XCTestCase {
    private let tex = """
        \\documentclass{article}
        \\newenvironment{BOX}[1]{\\begin{list}{}{#1}}{\\end{list}}
        \\begin{document}
        \\begin{BOX}{1cm}
        Visible entry text.
        \\index{entry@\\texttt{entry}}%
        \\end{BOX}
        \\begin{BOX}{1cm} trailing words
        \\begin{UNKNOWN}{1cm}
        Last line.
        \\end{document}
        """

    private func isFolded(_ storage: NSTextStorage, line: String) -> Bool {
        let location = (storage.string as NSString).range(of: line).location
        XCTAssertNotEqual(location, NSNotFound, line)
        let font = storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        return (font?.pointSize ?? 12) < 3
    }

    func testEnvironmentBoundaryAndIndexLinesFold() {
        let storage = NSTextStorage(string: tex)
        LaTeXLiveStyler.applyStyles(
            to: storage, theme: .daylight, sourceCodeMode: false, prettyMode: true, focusMode: false,
            selectedRange: NSRange(location: (tex as NSString).length, length: 0), containerWidth: 700
        )
        XCTAssertTrue(isFolded(storage, line: "\\begin{BOX}{1cm}\n"))
        XCTAssertTrue(isFolded(storage, line: "\\end{BOX}"))
        XCTAssertTrue(isFolded(storage, line: "\\index{entry"))
        XCTAssertFalse(isFolded(storage, line: "Visible entry text."))
        XCTAssertFalse(isFolded(storage, line: "\\begin{BOX}{1cm} trailing"), "a begin line with text after its arguments stays")
        XCTAssertFalse(isFolded(storage, line: "\\begin{UNKNOWN}"), "only environments the document defines fold")
    }

    func testIndexOnlyLineDetection() {
        XCTAssertTrue(LaTeXLiveStyler.isIndexOnlyLine("\\index{a}\\index{b@$b$} % note"))
        XCTAssertFalse(LaTeXLiveStyler.isIndexOnlyLine("\\index{a} text"))
        XCTAssertFalse(LaTeXLiveStyler.isIndexOnlyLine("\\index{unclosed"))
    }
}
