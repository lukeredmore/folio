import AppKit
import XCTest
@testable import OpenType

final class OpenTypeTests: XCTestCase {

    func testHeadingAndDecorationExtraction() {
        let sample = """
        # Main Title
        Some intro with **bold** and `code`.

        ## Section Two
        > A blockquote line

        ---

        ```swift
        let x = 42
        ```

        | Col A | Col B |
        | --- | --- |
        | 1 | 2 |
        """

        let storage = NSTextStorage(string: sample)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(analysis.headings.count, 2)
        XCTAssertEqual(analysis.headings[0].level, 1)
        XCTAssertEqual(analysis.headings[0].title, "Main Title")
        XCTAssertEqual(analysis.headings[1].level, 2)
        XCTAssertEqual(analysis.headings[1].title, "Section Two")

        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .headingUnderline(level: 1) }))
        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .blockquote(nestLevel: 1) }))
        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .horizontalRule }))
        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .codeFenceStart(language: "swift") }))
        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .tableHeaderRow }))
    }

    func testActiveLineRevealsSyntaxWhileInactiveLineCollapsesSyntax() {
        let sample = "# Heading One\n## Heading Two"
        let storage = NSTextStorage(string: sample)

        // Cursor at index 0 (on "# Heading One")
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        // Line 1 "#" token at index 0 should be visible (non-zero alpha)
        let line1HashColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(line1HashColor)
        XCTAssertGreaterThan(line1HashColor?.alphaComponent ?? 0, 0.5)

        // Line 2 "##" token at index 14 should be collapsed (clear color, 0.1pt font)
        let line2Start = (sample as NSString).range(of: "##").location
        let line2HashColor = storage.attribute(.foregroundColor, at: line2Start, effectiveRange: nil) as? NSColor
        XCTAssertEqual(line2HashColor?.alphaComponent ?? 1.0, 0.0, accuracy: 0.001)
    }

    func testDocumentStatsComputation() {
        let text = "Hello world from OpenType.\nSecond line here."
        let stats = DocumentStats.compute(for: text, selectedRange: NSRange(location: 0, length: 11))
        XCTAssertEqual(stats.words, 7)
        XCTAssertEqual(stats.lines, 2)
        XCTAssertEqual(stats.selectedWords, 2)
        XCTAssertEqual(stats.selectedCharacters, 11)
    }

    func testAllSixEditorThemes() {
        XCTAssertEqual(EditorTheme.allCases.count, 6)
        for theme in EditorTheme.allCases {
            XCTAssertGreaterThan(theme.baseFontSize, 12)
            XCTAssertGreaterThan(theme.maxWriteWidth, 600)
        }
        XCTAssertTrue(EditorTheme.midnight.isDark)
        XCTAssertFalse(EditorTheme.daylight.isDark)
    }
}
