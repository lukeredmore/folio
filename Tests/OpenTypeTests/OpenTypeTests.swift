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
        XCTAssertTrue(analysis.decorations.contains(where: {
            if case .tableRow(let isHeader, _, let isFirst, _, _, _, _) = $0.kind {
                return isHeader && isFirst
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

    func testLaTeXMathRendererLayoutAndDecorations() {
        let node = LaTeXMathRenderer.parse(#"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}"#)
        let box = LaTeXMathRenderer.layout(node: node, baseFontSize: 18, isDisplayStyle: true)
        XCTAssertGreaterThan(box.width, 60)
        XCTAssertGreaterThan(box.ascent, 12)
        XCTAssertGreaterThan(box.descent, 6)

        let sample = """
        First line here.
        Inline math $\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}$ here.

        $$
        \\mathcal{L}_{\\text{OpenType}} = \\int_{-\\infty}^{\\infty} e^{-x^2} dx
        $$
        """
        let storage = NSTextStorage(string: sample)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertTrue(analysis.decorations.contains(where: {
            if case .inlineMathRendered(let latex, _, _, _) = $0.kind {
                return latex.contains("nabla")
            }
            return false
        }), "Inactive line with $...$ should produce an inlineMathRendered decoration")

        XCTAssertTrue(analysis.decorations.contains(where: {
            if case .mathBlockRendered(let latex, _, _) = $0.kind {
                return latex.contains("int")
            }
            return false
        }), "Inactive $$...$$ block should produce a mathBlockRendered decoration")
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

    func testTypographySettingsCustomization() {
        let sample = "# Main Title\n\nBody paragraph text.\n\n---\n"
        let storage = NSTextStorage(string: sample)
        let customTypo = EditorTypographySettings(
            fontSizeScale: 1.15,
            lineHeightMultiple: 1.40,
            lineSpacing: 9.0,
            paragraphSpacing: 16.0,
            characterSpacing: 0.45,
            headingCharacterSpacing: 0.85,
            headingSpacingScale: 1.25,
            headingUnderlineOffset: 10.0,
            showHeadingUnderlines: true,
            maxColumnWidth: 920.0
        )

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: customTypo,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 20, length: 0)
        )

        let titleLoc = (sample as NSString).range(of: "Main Title").location
        let titleKern = storage.attribute(.kern, at: titleLoc, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(titleKern ?? 0.0, 0.85, accuracy: 0.01)

        let bodyLoc = (sample as NSString).range(of: "Body paragraph").location
        let bodyKern = storage.attribute(.kern, at: bodyLoc, effectiveRange: nil) as? CGFloat
        XCTAssertEqual(bodyKern ?? 0.0, 0.45, accuracy: 0.01)

        let bodyPara = storage.attribute(.paragraphStyle, at: bodyLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(bodyPara?.lineSpacing ?? 0.0, 9.0, accuracy: 0.01)
        XCTAssertEqual(bodyPara?.lineHeightMultiple ?? 0.0, 1.40, accuracy: 0.01)

        let hrLoc = (sample as NSString).range(of: "---").location
        let hrPara = storage.attribute(.paragraphStyle, at: hrLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(hrPara?.minimumLineHeight ?? 0.0, 28.0, accuracy: 0.01)

        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .headingUnderline(level: 1) }))
    }
}

