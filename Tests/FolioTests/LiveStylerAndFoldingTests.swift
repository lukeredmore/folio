import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class LiveStylerAndFoldingTests: XCTestCase {

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
        XCTAssertTrue(analysis.decorations.contains(where: {
            if case .tableRow(let isHeader, _, let isFirst, _, _, let offsetX, let tableWidth, _) = $0.kind {
                return isHeader && isFirst && offsetX >= 0 && tableWidth >= 600
            }
            return false
        }))
    }

    func testMultiBacktickInlineCodeDoesNotLeakIntoSurroundingText() {
        let sample = #"> **Seamless Live Rendering**: Place your cursor on any line to reveal and edit its raw Markdown tokens (`#`, `**`, `` ` ``, `[link](url)`). Move the cursor away and the syntax markers collapse cleanly into live typography—with zero WebView overhead."#
        let storage = NSTextStorage(string: sample)
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: sample.count, length: 0)
        )

        // The comma/space ", " between `` ` `` and `[link](url)` and the trailing prose must NOT have inlineCodeNSColor
        let proseRange = (sample as NSString).range(of: "Move the cursor away")
        XCTAssertNotEqual(proseRange.location, NSNotFound)
        let fg = storage.attribute(.foregroundColor, at: proseRange.location, effectiveRange: nil) as? NSColor
        let bg = storage.attribute(.backgroundColor, at: proseRange.location, effectiveRange: nil) as? NSColor
        XCTAssertNil(bg, "Prose outside backtick spans must not receive inline code background color")
        XCTAssertNotEqual(fg, EditorTheme.daylight.inlineCodeNSColor, "Prose outside backtick spans must not receive red inline code color")
    }

    func testCodeFenceLanguageSwitchChangesHighlighting() {
        let swiftCode = """
        ```swift
        def hello():
            let x = 1
        ```
        """
        let pythonCode = """
        ```python
        def hello():
            let x = 1
        ```
        """
        let swiftStorage = NSTextStorage(string: swiftCode)
        _ = MarkdownLiveStyler.applyStyles(
            to: swiftStorage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let pyStorage = NSTextStorage(string: pythonCode)
        _ = MarkdownLiveStyler.applyStyles(
            to: pyStorage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let swiftDefLoc = (swiftCode as NSString).range(of: "def").location
        let pyDefLoc = (pythonCode as NSString).range(of: "def").location

        let swiftDefColor = swiftStorage.attribute(.foregroundColor, at: swiftDefLoc, effectiveRange: nil) as? NSColor
        let pyDefColor = pyStorage.attribute(.foregroundColor, at: pyDefLoc, effectiveRange: nil) as? NSColor

        // In Python, `def` is a keyword; in Swift, `def` is plain text
        XCTAssertNotEqual(swiftDefColor, pyDefColor)
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

    func testNestedInlineFormattingWhenUnselected() {
        let sample = """
        First active line with cursor.
        - **[`architecture/`](./architecture/README.md)** — Core architecture docs
        - **Bold with `inline_code` and *nested italic* inside**
        - *Italic with `code_span` and foo_bar_baz underscore*
        - ***Bold and italic together***
        """
        let storage = NSTextStorage(string: sample)
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let ns = sample as NSString

        // 1. Verify **[`architecture/`](./architecture/README.md)** has collapsed**, [, `, ], (./architecture/README.md), **
        let archTextRange = ns.range(of: "architecture/")
        XCTAssertNotEqual(archTextRange.location, NSNotFound)
        let archFg = storage.attribute(.foregroundColor, at: archTextRange.location, effectiveRange: nil) as? NSColor
        // Link color or inline code inside link
        XCTAssertNotNil(archFg)
        XCTAssertGreaterThan(archFg?.alphaComponent ?? 0, 0.5, "Visible link/code text must not be collapsed")

        // The URL part "(./architecture/README.md)" and outer "**" must be collapsed when unselected
        let urlRange = ns.range(of: "(./architecture/README.md)")
        let urlFg = storage.attribute(.foregroundColor, at: urlRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(urlFg?.alphaComponent ?? 1.0, 0.0, accuracy: 0.001, "Markdown link URL must be collapsed when unselected")

        let outerBoldMarker = ns.range(of: "**[`architecture/`]")
        let markerFg = storage.attribute(.foregroundColor, at: outerBoldMarker.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(markerFg?.alphaComponent ?? 1.0, 0.0, accuracy: 0.001, "Outer ** around link with code must be collapsed when unselected")

        // 2. Verify **Bold with `inline_code` and *nested italic* inside**
        let boldWordLoc = ns.range(of: "Bold with").location
        let boldFont = storage.attribute(.font, at: boldWordLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(boldFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont!).contains(.boldFontMask), "Outer bold containing inline code must still apply bold font trait")

        let nestedItalicLoc = ns.range(of: "nested italic").location
        let nestedFont = storage.attribute(.font, at: nestedItalicLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(nestedFont)
        let nestedTraits = NSFontManager.shared.traits(of: nestedFont!)
        XCTAssertTrue(nestedTraits.contains(.boldFontMask), "Nested italic inside bold should preserve bold trait")
        XCTAssertTrue(nestedTraits.contains(.italicFontMask), "Nested italic inside bold should have italic trait")

        // 3. Verify *Italic with `code_span` and foo_bar_baz underscore*
        let italicWordLoc = ns.range(of: "foo_bar_baz").location
        let italicFont = storage.attribute(.font, at: italicWordLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(italicFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italicFont!).contains(.italicFontMask), "Italic span containing intraword underscores and inline code must be styled italic")

        // 4. Verify ***Bold and italic together***
        let tripleLoc = ns.range(of: "Bold and italic together").location
        let tripleFont = storage.attribute(.font, at: tripleLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(tripleFont)
        let tripleTraits = NSFontManager.shared.traits(of: tripleFont!)
        XCTAssertTrue(tripleTraits.contains(.boldFontMask))
        XCTAssertTrue(tripleTraits.contains(.italicFontMask))
    }

    func testCommonMarkSetextHeadingsTildeFencesAndEscapes() {
        let sample = """
        Cursor line.

        Setext Heading 1
        ================

        Setext Heading 2
        ----------------

        ~~~rust
        fn main() {}
        ~~~

        Escaped \\*not italic\\* and autolink <https://example.com/docs>.
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
        XCTAssertEqual(analysis.headings[0].title, "Setext Heading 1")
        XCTAssertEqual(analysis.headings[1].level, 2)
        XCTAssertEqual(analysis.headings[1].title, "Setext Heading 2")

        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .codeFenceStart(language: "rust") }))

        let ns = sample as NSString
        let notItalicLoc = ns.range(of: "not italic").location
        let notItalicFont = storage.attribute(.font, at: notItalicLoc, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(notItalicFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: notItalicFont!).contains(.italicFontMask), "Escaped \\*not italic\\* must not become italic")

        // Backslash before '*' should be collapsed when unselected
        let backslashLoc = ns.range(of: "\\*not").location
        let backslashFg = storage.attribute(.foregroundColor, at: backslashLoc, effectiveRange: nil) as? NSColor
        XCTAssertEqual(backslashFg?.alphaComponent ?? 1.0, 0.0, accuracy: 0.001, "Escape backslash should collapse when unselected")
    }
}
