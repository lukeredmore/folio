import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class FolioTests: XCTestCase {

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
        \\mathcal{L}_{\\text{Folio}} = \\int_{-\\infty}^{\\infty} e^{-x^2} dx
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
        let text = "Hello world from Folio.\nSecond line here."
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

    func testCoreEngineFFIIntegration() {
        let ffiBox = LaTeXMathRenderer.layoutLatex(#"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}"#, baseFontSize: 18, isDisplayStyle: true)
        XCTAssertGreaterThan(ffiBox.width, 60)
        XCTAssertGreaterThan(ffiBox.ascent, 12)
        XCTAssertGreaterThan(ffiBox.descent, 6)

        let plain = LaTeXMathRenderer.plainTextSummary(of: #"\frac{\alpha}{\beta}"#)
        XCTAssertTrue(plain.contains("α"))
        XCTAssertTrue(plain.contains("β"))
    }

    func testAppUpdateManagerRollingAndVersionedComparisons() throws {
        let installed = AppVersionInfo(
            shortVersion: "1.0.0",
            buildNumber: 12,
            commitSHA: "3f15af8",
            engineVersion: "0.1.0",
            repository: "lukeredmore/folio"
        )

        // 1. Same version and build number + matching SHA -> no update
        let sameBuild = ReleaseManifest(
            version: "1.0.0",
            buildNumber: 12,
            commitSHA: "3f15af8",
            engineVersion: "0.1.0",
            publishedAt: "2026-10-18T19:00:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: ""
        )
        XCTAssertFalse(AppUpdateManager.isUpdateAvailable(current: installed, remote: sameBuild))

        // 2. Rolling update WITHOUT marketing version change (1.0.0 build #12 -> 1.0.0 build #13)
        let rollingNewerBuild = ReleaseManifest(
            version: "1.0.0",
            buildNumber: 13,
            commitSHA: "a91bc02",
            engineVersion: "0.2.0",
            publishedAt: "2026-10-18T19:30:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: ""
        )
        XCTAssertTrue(AppUpdateManager.isUpdateAvailable(current: installed, remote: rollingNewerBuild))

        // 3. Semantic version bump (1.0.0 -> 1.1.0)
        let semverBump = ReleaseManifest(
            version: "1.1.0",
            buildNumber: 1,
            commitSHA: "b82cd11",
            engineVersion: "0.2.0",
            publishedAt: "2026-10-18T20:00:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: ""
        )
        XCTAssertTrue(AppUpdateManager.isUpdateAvailable(current: installed, remote: semverBump))

        // 4. Verify SHA-256 helper
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("folio-sha-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try Data("folio-dmg-payload".utf8).write(to: tempFile)
        // SHA-256("folio-dmg-payload") = cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e
        XCTAssertTrue(try AppUpdateManager.verifySHA256(
            fileURL: tempFile,
            expectedHex: "cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e"
        ))
        XCTAssertFalse(try AppUpdateManager.verifySHA256(
            fileURL: tempFile,
            expectedHex: "0000000000000000000000000000000000000000000000000000000000000000"
        ))

        // 5. Parse GitHub Releases REST API payload directly (no external JSON file needed)
        let ghReleasePayload = """
        {
          "tag_name": "latest",
          "name": "Folio v1.0.0 (Build #15 — 9f8e7d6)",
          "published_at": "2026-10-18T20:15:00Z",
          "body": "Automated rolling macOS build.\\n\\n<!-- folio-release: {\\"version\\":\\"1.0.0\\",\\"build_number\\":15,\\"commit_sha\\":\\"9f8e7d6\\",\\"engine_version\\":\\"0.1.0\\",\\"published_at\\":\\"2026-10-18T20:15:00Z\\",\\"dmg_url\\":\\"https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg\\",\\"dmg_sha256\\":\\"cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e\\",\\"notes\\":\\"feat: rolling update\\"} -->",
          "assets": [
            {
              "name": "Folio.dmg",
              "browser_download_url": "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
              "digest": "sha256:cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try ReleaseManifest.fromGitHubReleaseAPI(data: ghReleasePayload)
        XCTAssertEqual(parsed.version, "1.0.0")
        XCTAssertEqual(parsed.buildNumber, 15)
        XCTAssertEqual(parsed.commitSHA, "9f8e7d6")
        XCTAssertEqual(parsed.notes, "feat: rolling update")
        XCTAssertTrue(AppUpdateManager.isUpdateAvailable(current: installed, remote: parsed))
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

    func testComplicatedAndWideTablesDoNotBreakOrShrink() {
        let sample = """
        Cursor line at top.

        | Subsystem | Primary Files | Inline Code & Pipes | Description & Details |
        | :--- | :--- | :--- | :--- |
        | **[`architecture/`](./architecture/README.md)** | `core/folio_engine/src/markdown.rs` | `a | b || c` and \\| escaped | Full CommonMark + GFM specification parser with nested spans `<br/>` and wide columns |
        | **Live Styler** | [`MarkdownLiveStyler.swift`](Sources/Folio/Editor/MarkdownLiveStyler.swift) | `$|x| + |y|$` | Preserves natural column widths and allows horizontal scrolling past the prose canvas width |
        """

        let narrowContainerWidth: CGFloat = 520.0
        let storage = NSTextStorage(string: sample)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: narrowContainerWidth
        )

        let tableDecs = analysis.decorations.compactMap { dec -> (Bool, Bool, CGFloat, CGFloat, [CGFloat])? in
            if case .tableRow(let isHeader, let isSep, _, _, _, let offsetX, let tableWidth, let columnDividers) = dec.kind {
                return (isHeader, isSep, offsetX, tableWidth, columnDividers)
            }
            return nil
        }

        XCTAssertEqual(tableDecs.count, 4, "All 4 lines of the complicated table must be recognized as a single table block")
        let firstRow = tableDecs[0]
        XCTAssertTrue(firstRow.0, "First row must be header")
        XCTAssertEqual(firstRow.4.count, 3, "4 columns must produce 3 interior column dividers; pipes inside inline code, math, and escaped \\| must not split extra columns")
        XCTAssertGreaterThan(firstRow.3, narrowContainerWidth, "Wide table must exceed narrow containerWidth instead of shrinking columns")
        XCTAssertEqual(firstRow.2, 0.0, accuracy: 0.01, "Wide table should have 0 horizontal centering offset")

        // Verify paragraph style on table rows prevents soft-wrapping
        let ns = sample as NSString
        let dataRowLoc = ns.range(of: "Live Styler").location
        let para = storage.attribute(.paragraphStyle, at: dataRowLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.lineBreakMode, .byClipping, "Table rows must use .byClipping so wide tables never soft-wrap")
    }

    func testWhitespaceNormalizationAndListAlignment() {
        let sample = """
        Active line at top.
           Leading spaces and   multiple    internal   spaces.
        -    Bullet with extra spaces after marker
          Continuation line under bullet
        1.    Ordered item with extra spaces
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

        // Leading spaces on inactive prose line should be collapsed
        let leadingSpaceRange = ns.range(of: "   Leading")
        let firstLeadingSpaceFont = storage.attribute(.font, at: leadingSpaceRange.location, effectiveRange: nil) as? NSFont
        XCTAssertLessThanOrEqual(firstLeadingSpaceFont?.pointSize ?? 16.0, 0.2, "Leading spaces on prose line should be collapsed when unselected")

        // Extra spaces in "   multiple" should have 1st space visible and 2nd/3rd spaces collapsed
        let multiSpaceRange = ns.range(of: "   multiple")
        let firstInternalSpaceFont = storage.attribute(.font, at: multiSpaceRange.location, effectiveRange: nil) as? NSFont
        let secondInternalSpaceFont = storage.attribute(.font, at: multiSpaceRange.location + 1, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(firstInternalSpaceFont?.pointSize ?? 0.0, 10.0, "First space of internal whitespace run must remain a normal space")
        XCTAssertLessThanOrEqual(secondInternalSpaceFont?.pointSize ?? 16.0, 0.2, "Subsequent spaces in internal whitespace run must collapse per CommonMark")

        // List item marker + post-marker kern must advance text to headIndent, and continuation line must match headIndent
        let bulletMarkerLoc = ns.range(of: "-    Bullet").location
        let bulletLoc = ns.range(of: "Bullet with").location
        let bulletPara = storage.attribute(.paragraphStyle, at: bulletLoc, effectiveRange: nil) as? NSParagraphStyle
        let markerFont = storage.attribute(.font, at: bulletMarkerLoc, effectiveRange: nil) as? NSFont
        let postMarkerKern = storage.attribute(.kern, at: bulletMarkerLoc + 1, effectiveRange: nil) as? CGFloat
        XCTAssertNotNil(bulletPara)
        XCTAssertNotNil(markerFont)
        let markerWidth = ("-" as NSString).size(withAttributes: [.font: markerFont!]).width
        XCTAssertEqual(
            (bulletPara?.firstLineHeadIndent ?? 0) + markerWidth + (postMarkerKern ?? 0),
            bulletPara?.headIndent ?? -1,
            accuracy: 0.05,
            "List firstLineHeadIndent + markerWidth + postMarkerKern must equal headIndent so wrapped lines align"
        )

        let contLoc = ns.range(of: "Continuation line").location
        let contPara = storage.attribute(.paragraphStyle, at: contLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(contPara?.firstLineHeadIndent ?? -1, bulletPara?.headIndent ?? -2, accuracy: 0.01)
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

    @MainActor
    func testFilesViewerHidesNonMarkdownFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FolioFilterTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create Markdown files, non-Markdown files (.swift, .yaml, .json), and an empty/code-only subdir
        let readmeURL = tempDir.appendingPathComponent("README.md")
        let notesURL = tempDir.appendingPathComponent("guide.markdown")
        let swiftURL = tempDir.appendingPathComponent("main.swift")
        let yamlURL = tempDir.appendingPathComponent("config.yaml")

        let docsSubdir = tempDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsSubdir, withIntermediateDirectories: true)
        let archURL = docsSubdir.appendingPathComponent("architecture.md")
        let helperSwiftURL = docsSubdir.appendingPathComponent("helper.swift")

        let codeOnlySubdir = tempDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: codeOnlySubdir, withIntermediateDirectories: true)
        let appSwiftURL = codeOnlySubdir.appendingPathComponent("App.swift")

        try "# Readme".write(to: readmeURL, atomically: true, encoding: .utf8)
        try "# Guide".write(to: notesURL, atomically: true, encoding: .utf8)
        try "import Foundation".write(to: swiftURL, atomically: true, encoding: .utf8)
        try "key: value".write(to: yamlURL, atomically: true, encoding: .utf8)
        try "# Architecture".write(to: archURL, atomically: true, encoding: .utf8)
        try "struct Helper {}".write(to: helperSwiftURL, atomically: true, encoding: .utf8)
        try "struct App {}".write(to: appSwiftURL, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel()
        vm.loadWorkspaceFolder(tempDir)

        // Flat list should only contain the 3 Markdown files
        let flatNames = Set(vm.flatMarkdownFiles.map(\.name))
        XCTAssertEqual(flatNames, ["README.md", "guide.markdown", "architecture.md"])
        XCTAssertFalse(flatNames.contains("main.swift"))
        XCTAssertFalse(flatNames.contains("config.yaml"))

        // Tree root nodes should only contain "docs" directory, "README.md", and "guide.markdown"
        // (no "main.swift", no "config.yaml", and no "Sources" directory since it has no Markdown files)
        let rootNames = Set(vm.rootFileNodes.map(\.name))
        XCTAssertEqual(rootNames, ["docs", "README.md", "guide.markdown"])

        if let docsNode = vm.rootFileNodes.first(where: { $0.name == "docs" }) {
            let docsChildrenNames = Set((docsNode.children ?? []).map(\.name))
            XCTAssertEqual(docsChildrenNames, ["architecture.md"])
        } else {
            XCTFail("Expected 'docs' directory node in rootFileNodes")
        }
    }

    private struct UpstreamSpecTestEntry: Decodable {
        let example: Int
        let section: String
        let markdown: String
        let html: String
        let extensions: [String]
    }

    private func locateSpecFixture(_ relativePath: String) throws -> URL {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = [relativePath]
        if let testSrcdir = env["TEST_SRCDIR"] {
            let workspace = env["TEST_WORKSPACE"] ?? "_main"
            candidates.append("\(testSrcdir)/\(workspace)/\(relativePath)")
            candidates.append("\(testSrcdir)/folio/\(relativePath)")
        }
        if let pwd = env["PWD"] {
            candidates.append("\(pwd)/\(relativePath)")
        }
        for candidate in candidates {
            if fm.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw NSError(domain: "FolioTests", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing spec fixture: \(relativePath)"])
    }

    func testUpstreamGFMSpecAndExtensionsFullParity() throws {
        let gfmSpecURL = try locateSpecFixture("third_party/markdown_spec/gfm_spec.json")
        let gfmExtURL = try locateSpecFixture("third_party/markdown_spec/gfm_extensions.json")

        let gfmSpecData = try Data(contentsOf: gfmSpecURL)
        let gfmExtData = try Data(contentsOf: gfmExtURL)

        let specEntries = try JSONDecoder().decode([UpstreamSpecTestEntry].self, from: gfmSpecData)
        let extEntries = try JSONDecoder().decode([UpstreamSpecTestEntry].self, from: gfmExtData)

        XCTAssertGreaterThanOrEqual(specEntries.count, 670, "Expected at least 670 upstream GFM spec examples")
        XCTAssertGreaterThanOrEqual(extEntries.count, 30, "Expected at least 30 upstream GFM extensions examples")

        var failures: [String] = []
        for entry in specEntries {
            let actual = MarkdownLiveStyler.renderHTML(entry.markdown, extensions: entry.extensions)
            if actual != entry.html {
                failures.append("gfm_spec.json Example \(entry.example) (\(entry.section)): expected \(entry.html.debugDescription), got \(actual.debugDescription)")
            }
        }
        let defaultExtSuite = ["table", "strikethrough", "autolink", "tagfilter", "footnotes", "tasklist"]
        for entry in extEntries {
            guard entry.html.trimmingCharacters(in: .whitespacesAndNewlines) != "<IGNORE>" else { continue }
            var exts = defaultExtSuite
            for ext in entry.extensions where !exts.contains(ext) {
                exts.append(ext)
            }
            let actual = MarkdownLiveStyler.renderHTML(entry.markdown, extensions: exts)
            if actual != entry.html {
                failures.append("gfm_extensions.json Example \(entry.example) (\(entry.section)): expected \(entry.html.debugDescription), got \(actual.debugDescription)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Failed \(failures.count) upstream GFM spec tests:\n\(failures.prefix(10).joined(separator: "\n"))"
        )
    }

    @MainActor
    func testCmarkGfmASTLiveBufferStylingParity() {
        let sample = """
        # Active Line

            let indentedCode = 42
            return indentedCode

        See [Reference Label][docs] and [Collapsed][] and visit www.commonmark.org today.

        [docs]: https://commonmark.org/help
        [collapsed]: https://github.github.com/gfm/
        """

        let storage = NSTextStorage(string: sample)
        let theme = EditorTheme.daylight

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: theme,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        // 1. Indented code block lines should produce .codeFenceBody decorations
        let indentedDecorations = analysis.decorations.filter { $0.kind == .codeFenceBody }
        XCTAssertEqual(indentedDecorations.count, 2, "Expected 2 indented code block line decorations from cmark-gfm AST")

        let ns = sample as NSString
        // 2. Reference link `[Reference Label][docs]` should style `Reference Label` as link and collapse `[` and `][docs]`
        let refLabelRange = ns.range(of: "Reference Label")
        let refLabelColor = storage.attribute(.foregroundColor, at: refLabelRange.location, effectiveRange: nil) as? NSColor
        let refLabelUnderline = storage.attribute(.underlineStyle, at: refLabelRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(refLabelColor, theme.linkNSColor)
        XCTAssertEqual(refLabelUnderline, NSUnderlineStyle.single.rawValue)

        let trailingRefSyntax = ns.range(of: "][docs]")
        let trailingRefFont = storage.attribute(.font, at: trailingRefSyntax.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(trailingRefFont?.pointSize ?? 12.0, 0.001, accuracy: 0.01, "Reference link suffix ][docs] should collapse on unselected lines")

        // 3. Collapsed reference link `[Collapsed][]` should style `Collapsed` as link
        let collapsedRange = ns.range(of: "Collapsed")
        let collapsedColor = storage.attribute(.foregroundColor, at: collapsedRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(collapsedColor, theme.linkNSColor)

        // 4. GFM extended autolink `www.commonmark.org` should style as link
        let bareAutolinkRange = ns.range(of: "www.commonmark.org")
        let bareAutolinkColor = storage.attribute(.foregroundColor, at: bareAutolinkRange.location, effectiveRange: nil) as? NSColor
        let bareAutolinkUnderline = storage.attribute(.underlineStyle, at: bareAutolinkRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(bareAutolinkColor, theme.linkNSColor)
        XCTAssertEqual(bareAutolinkUnderline, NSUnderlineStyle.single.rawValue)
    }

    @MainActor
    func testUnmatchedEmphasisDoesNotBacktrackOrHang() throws {
        // Regression test for catastrophic O(2^N) backtracking when a line contains an unmatched
        // opening `_` or `*` delimiter (such as `_subscriptions: Vec<Subscription>` inside inline code
        // in AGENTS.md) followed by 40+ characters without a matching closing delimiter.
        let pathologicalMarkdown = """
        # Agent Guidelines

        - When calling `cx.subscribe`, `cx.observe`, etc., never drop the returned `Subscription` without storing it (e.g., `cx.subscribe(...).detach()` is almost always a bug, unless `cx` is the `App` itself). Store subscriptions in a `_subscriptions: Vec<Subscription>` field on the struct so they are tied to the entity's lifetime.
        - Another line with unmatched *asterisk delimiter followed by a long sequence of words that has no closing asterisk anywhere on the line at all.
        - And an unmatched _underscore delimiter followed by a very long sequence of characters without any closing underscore anywhere on this line either!
        """

        let start = CFAbsoluteTimeGetCurrent()
        let storage = NSTextStorage(string: pathologicalMarkdown)
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 720
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.3, "Styling unmatched emphasis delimiters should be O(N) and complete in <300ms, took \(elapsed)s")

        // Also verify full MainWindowView + HybridMarkdownTextView layout with AGENTS.md files if present on disk
        let candidatePaths = [
            "/Users/lukeredmore/Developer/Folio/third_party/zed/upstream/AGENTS.md",
            "/Users/lukeredmore/Developer/PDLaunch/AGENTS.md"
        ]
        let vm = EditorWorkspaceViewModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 901, height: 1036),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        window.displayIfNeeded()

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            let t0 = CFAbsoluteTimeGetCurrent()
            vm.openFile(at: URL(fileURLWithPath: path))
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            window.displayIfNeeded()
            let dt = CFAbsoluteTimeGetCurrent() - t0
            XCTAssertLessThan(dt, 0.5, "Opening and rendering \(path) should complete in <0.5s, took \(dt)s")
        }
    }

    @MainActor
    func testAdversarialMarkdownAndLatexNoExplosions() throws {
        // Comprehensive pentest suite for algorithmic complexity attacks (ReDoS, O(N^2) scanners,
        // stack-overflow recursion, and infinite loops on malformed delimiters).
        let n = 1500
        let adversarialLines: [String] = [
            // 1. Cubic O(N^3) hrRegex attack: alternating hyphens and spaces ending with non-hyphen
            String(repeating: "- ", count: n) + "a",
            String(repeating: "* ", count: n) + "a",
            String(repeating: "_ ", count: n) + "a",
            // 2. Quadratic O(N^2) headingRegex attack: trailing spaces + hashes + non-hash
            "# " + String(repeating: " ", count: n) + String(repeating: "#", count: n) + "a",
            // 3. Quadratic O(N^2) autolink email domain attack without closing '>'
            "<user@" + String(repeating: "a.", count: n),
            // 4. Repeated unmatched inline code backtick runs of different lengths
            String(repeating: "`a ", count: n),
            String(repeating: "``a ", count: n),
            String(repeating: "```a ", count: n),
            // 5. Repeated unmatched emphasis, strikethrough, and highlight openers
            String(repeating: "*a ", count: n),
            String(repeating: "_a ", count: n),
            String(repeating: "**a ", count: n),
            String(repeating: "__a ", count: n),
            String(repeating: "***a ", count: n),
            String(repeating: "~~a ", count: n),
            String(repeating: "==a ", count: n),
            // 6. Repeated unmatched brackets and unclosed link destinations
            String(repeating: "[a ", count: n),
            String(repeating: "[a](https://example.com/", count: n / 2),
            String(repeating: "[outer ", count: n) + "[inner](https://example.com)",
            // 7. Table candidate line with pipes and thousands of unmatched backticks and '$'
            "| " + String(repeating: "`a ", count: n) + " | " + String(repeating: "$a ", count: n) + " |",
        ]
        let adversarialMarkdown = adversarialLines.joined(separator: "\n\n")

        let start = CFAbsoluteTimeGetCurrent()
        let storage = NSTextStorage(string: adversarialMarkdown)
        let doc = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 720
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(
            elapsed,
            1.0,
            "Adversarial Markdown pentest suite should run in linear time (<1.0s), took \(elapsed)s"
        )
        XCTAssertEqual(doc.headings.count, 1)

        // 8. LaTeX parser pentests: deeply nested braces, scripts, stray '}', and \left...\rightarrow...\right
        let deepBraces = String(repeating: "{", count: 500) + "x+1" + String(repeating: "}", count: 500)
        let deepSupers = String(repeating: "x^", count: 500) + "2"
        let strayClosingBraces = "}}}}}}x + y}}}}}}"
        let leftWithRightArrow = #"\left( a \rightarrow b } c \right)"#

        let latexStart = CFAbsoluteTimeGetCurrent()
        let node1 = LaTeXMathRenderer.parse(deepBraces)
        let node2 = LaTeXMathRenderer.parse(deepSupers)
        let node3 = LaTeXMathRenderer.parse(strayClosingBraces)
        let node4 = LaTeXMathRenderer.parse(leftWithRightArrow)
        let box1 = LaTeXMathRenderer.layout(node: node1, baseFontSize: 16, isDisplayStyle: true)
        let box4 = LaTeXMathRenderer.layoutLatex(leftWithRightArrow, baseFontSize: 16, isDisplayStyle: true)
        let summary4 = LaTeXMathRenderer.plainTextSummary(of: leftWithRightArrow)
        let latexElapsed = CFAbsoluteTimeGetCurrent() - latexStart
        XCTAssertLessThan(
            latexElapsed,
            0.5,
            "Adversarial LaTeX pentest suite should complete in <500ms, took \(latexElapsed)s"
        )
        XCTAssertGreaterThan(box1.width, 0)
        XCTAssertGreaterThan(box4.width, 0)
        XCTAssertTrue(summary4.contains("→"))
        _ = (node2, node3, node4)
    }

    @MainActor
    func testListBulletCenteringAndConsistentIndentation() throws {
        let md = "* Active item\n* Inactive item\n"
        let storage = NSTextStorage(string: md)
        let doc = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 720
        )

        let ns = md as NSString
        let activeLineLoc = ns.range(of: "* Active item").location
        let inactiveLineLoc = ns.range(of: "* Inactive item").location

        let activePara = storage.attribute(.paragraphStyle, at: activeLineLoc, effectiveRange: nil) as? NSParagraphStyle
        let inactivePara = storage.attribute(.paragraphStyle, at: inactiveLineLoc, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertNotNil(activePara)
        XCTAssertNotNil(inactivePara)
        XCTAssertEqual(activePara?.firstLineHeadIndent, inactivePara?.firstLineHeadIndent, "Active and inactive top-level list items must have identical firstLineHeadIndent")
        XCTAssertEqual(activePara?.headIndent, inactivePara?.headIndent, "Active and inactive list items must have identical hanging headIndent")

        // Active '*' marker should have negative baselineOffset so it is vertically centered
        let activeBaselineOffset = storage.attribute(.baselineOffset, at: activeLineLoc, effectiveRange: nil) as? CGFloat
        XCTAssertNotNil(activeBaselineOffset)
        XCTAssertLessThan(activeBaselineOffset ?? 0, 0, "Active '*' marker should have negative baseline offset to vertically center the asterisk")

        // Inactive unordered list item should emit a .listBullet decoration
        let hasListBullet = doc.decorations.contains { dec in
            if case let .listBullet(range, _) = dec.kind {
                return range.location == inactiveLineLoc
            }
            return false
        }
        XCTAssertTrue(hasListBullet, "Inactive unordered list item should emit a .listBullet decoration for vertically centered bullet dot rendering")
    }

    func testRemoteMountSpecParsingAndSSHHelpers() throws {
        // 1. Standard scp-style user@host:/path
        let spec1 = try RemoteMountSpec.parse(
            connectionString: "luke@devbox.internal:/home/luke/notes",
            targetKind: .folder
        )
        XCTAssertEqual(spec1.user, "luke")
        XCTAssertEqual(spec1.host, "devbox.internal")
        XCTAssertEqual(spec1.port, 22)
        XCTAssertEqual(spec1.remotePath, "/home/luke/notes")
        XCTAssertEqual(spec1.targetKind, .folder)
        XCTAssertEqual(spec1.sshDestination, "luke@devbox.internal")
        XCTAssertEqual(spec1.label, "notes (devbox.internal)")

        // 2. Tilde path without explicit user
        let spec2 = try RemoteMountSpec.parse(
            connectionString: "prod-server:~/runbooks/incident.md",
            targetKind: .file,
            portOverride: 2222,
            displayName: "Prod Incident Runbook"
        )
        XCTAssertNil(spec2.user)
        XCTAssertEqual(spec2.host, "prod-server")
        XCTAssertEqual(spec2.port, 2222)
        XCTAssertEqual(spec2.remotePath, "~/runbooks/incident.md")
        XCTAssertEqual(spec2.targetKind, .file)
        XCTAssertEqual(spec2.label, "Prod Incident Runbook")

        // 3. ssh:// URL with port and tilde path
        let spec3 = try RemoteMountSpec.parse(
            connectionString: "ssh://ubuntu@10.0.1.42:2200/~/workspace/docs",
            targetKind: .folder
        )
        XCTAssertEqual(spec3.user, "ubuntu")
        XCTAssertEqual(spec3.host, "10.0.1.42")
        XCTAssertEqual(spec3.port, 2200)
        XCTAssertEqual(spec3.remotePath, "~/workspace/docs")

        // 4. Invalid connection string throws descriptive error
        XCTAssertThrowsError(try RemoteMountSpec.parse(connectionString: "invalid_missing_colon", targetKind: .folder))

        // 5. SSH shell escaping & snapshot parser
        XCTAssertEqual(SSHRemoteTransport.shellEscapePath("~/my notes/todo.md"), "\"$HOME\"/'my notes/todo.md'")
        XCTAssertEqual(SSHRemoteTransport.shellEscapePath("/var/docs/readme.md"), "'/var/docs/readme.md'")

        let rawContent1 = Data("# Remote Readme\nHello from SSH!\n".utf8).base64EncodedString()
        let rawContent2 = Data("## Subfolder Note\nFast local mirror.".utf8).base64EncodedString()
        let sampleStream = """
        ===FOLIO_FILE===\tREADME.md\t1729300000
        \(rawContent1)
        ===FOLIO_END===
        ===FOLIO_FILE===\tguides/setup.md\t1729300500
        \(rawContent2)
        ===FOLIO_END===
        """
        let entries = SSHRemoteTransport.parseSnapshotOutput(sampleStream)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].relativePath, "README.md")
        XCTAssertEqual(entries[0].content, "# Remote Readme\nHello from SSH!\n")
        XCTAssertEqual(entries[1].relativePath, "guides/setup.md")
        XCTAssertEqual(entries[1].content, "## Subfolder Note\nFast local mirror.")
    }

    @MainActor
    func testRemoteWorkspaceFolderAndFileMountUnifiedTreeAndSelfHealingSync() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolioRemoteTest_\(UUID().uuidString)", isDirectory: true)
        let localWorkspaceDir = tempRoot.appendingPathComponent("LocalNotes", isDirectory: true)
        let mirrorBaseDir = tempRoot.appendingPathComponent("Mirrors", isDirectory: true)
        try FileManager.default.createDirectory(at: localWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirrorBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let defaultsSuiteName = "com.folio.tests.remote.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { testDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        // Create a local file
        let localFileURL = localWorkspaceDir.appendingPathComponent("local_todo.md")
        try "# Local Todo\nBuy coffee and write Rust.".write(to: localFileURL, atomically: true, encoding: .utf8)

        // Configure MockRemoteTransport with a remote folder and a remote single file
        let mockTransport = MockRemoteTransport()
        let folderSpec = try RemoteMountSpec.parse(
            connectionString: "luke@devbox:/home/luke/cloud_notes",
            targetKind: .folder
        )
        let singleFileSpec = try RemoteMountSpec.parse(
            connectionString: "ops@prod:/etc/folio/runbook.md",
            targetKind: .file
        )

        mockTransport.setRemoteFiles(for: folderSpec.id, files: [
            "index.md": "# Cloud Index\nWelcome to remote folder sync.",
            "architecture/design.md": "# Distributed Sync\nFeels like local disk speed."
        ])
        mockTransport.setRemoteFiles(for: singleFileSpec.id, files: [
            "runbook.md": "# Prod Runbook\nAll systems nominal."
        ])

        let remoteManager = RemoteWorkspaceManager(
            transport: mockTransport,
            mirrorBaseDirectory: mirrorBaseDir,
            userDefaults: testDefaults
        )
        remoteManager.baseRetryDelaySeconds = 0.05

        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: remoteManager)
        vm.loadWorkspaceFolder(localWorkspaceDir)

        // Connect both the remote folder and the remote single file
        await vm.connectRemoteMount(folderSpec)
        await vm.connectRemoteMount(singleFileSpec)

        // 1. Verify unified multi-root sidebar tree & flatMarkdownFiles include local + remote folder + remote file
        let allFlatNames = Set(vm.flatMarkdownFiles.map(\.name))
        XCTAssertEqual(allFlatNames, ["local_todo.md", "index.md", "design.md", "runbook.md"])

        let remoteRootNodes = vm.rootFileNodes.filter(\.isRemoteRoot)
        XCTAssertEqual(remoteRootNodes.count, 2, "Expected 1 remote folder root and 1 remote single-file root in sidebar")
        XCTAssertEqual(remoteManager.connectionStates[folderSpec.id], .connected)
        XCTAssertEqual(remoteManager.connectionStates[singleFileSpec.id], .connected)
        XCTAssertTrue(remoteManager.unhealthyMounts.isEmpty)

        // 2. Verify Workspace Search works across both local and remote mirrored files at local speed
        vm.workspaceSearchQuery = "Distributed Sync"
        vm.performWorkspaceSearch()
        XCTAssertEqual(vm.workspaceSearchMatches.count, 1)
        XCTAssertEqual(vm.workspaceSearchMatches.first?.fileName, "design.md")

        // 3. Open remote file, edit, and save while connected -> instant local mirror update + remote push
        let designNode = try XCTUnwrap(vm.flatMarkdownFiles.first(where: { $0.name == "design.md" }))
        vm.openFile(at: designNode.url)
        XCTAssertEqual(vm.markdownText, "# Distributed Sync\nFeels like local disk speed.")

        vm.markdownText = "# Distributed Sync\nUpdated from native macOS editor!"
        vm.saveDocument()
        XCTAssertFalse(vm.isDirty)

        // Wait for the async save task to push to MockRemoteTransport
        for _ in 0..<50 {
            if mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md") == "# Distributed Sync\nUpdated from native macOS editor!"
                && remoteManager.syncStatus(forLocalURL: designNode.url) == .synced {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md"),
            "# Distributed Sync\nUpdated from native macOS editor!"
        )
        XCTAssertEqual(remoteManager.syncStatus(forLocalURL: designNode.url), .synced)

        // 4. Create a new file inside the remote folder -> created locally and pushed to remote
        let remoteFolderRootURL = remoteManager.mirrorRootURL(for: folderSpec)
        vm.createNewFileInWorkspace(in: remoteFolderRootURL)
        for _ in 0..<50 {
            if mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "Untitled.md") != nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(
            mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "Untitled.md"),
            "Newly created file inside remote folder should be pushed to remote host"
        )

        // 5. Simulate connection drop -> edit & save while offline -> clear error state + queued offline edit
        mockTransport.simulatedError = RemoteWorkspaceError.connectionFailed(
            host: "devbox",
            details: "ssh: connect to host devbox port 22: Operation timed out"
        )

        vm.openFile(at: designNode.url)
        vm.markdownText = "# Distributed Sync\nEdited while offline on airplane Wi-Fi!"
        vm.saveDocument()
        XCTAssertFalse(vm.isDirty, "Saving a remote file while offline must still succeed locally without blocking the user")

        for _ in 0..<50 {
            if remoteManager.syncStatus(forLocalURL: designNode.url) == .pendingUpload && !remoteManager.unhealthyMounts.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Verify file is marked pendingUpload and mount state is .reconnecting with clear error
        XCTAssertEqual(remoteManager.syncStatus(forLocalURL: designNode.url), .pendingUpload)
        XCTAssertEqual(remoteManager.unhealthyMounts.count, 1)
        XCTAssertEqual(remoteManager.unhealthyMounts.first?.0.id, folderSpec.id)
        XCTAssertTrue(remoteManager.unhealthyMounts.first?.1.errorMessage?.contains("Operation timed out") ?? false)

        // 6. Simulate connection recovery -> self-healing reconnect flushes pending queue and clears error state automatically
        mockTransport.simulatedError = nil
        for _ in 0..<100 {
            if remoteManager.connectionStates[folderSpec.id] == .connected
                && remoteManager.syncStatus(forLocalURL: designNode.url) == .synced {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(
            remoteManager.connectionStates[folderSpec.id],
            .connected,
            "Connection state should automatically self-heal to .connected once transport succeeds"
        )
        XCTAssertTrue(
            remoteManager.unhealthyMounts.isEmpty,
            "Unhealthy mounts banner should automatically clear once reconnected"
        )
        XCTAssertEqual(
            remoteManager.syncStatus(forLocalURL: designNode.url),
            .synced,
            "Queued offline edit should transition to .synced after self-healing reconnect"
        )
        XCTAssertEqual(
            mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md"),
            "# Distributed Sync\nEdited while offline on airplane Wi-Fi!",
            "Queued offline edit must be flushed to the remote server upon reconnection"
        )
    }
}

private final class MockRemoteTransport: RemoteFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UUID: [String: String]] = [:]
    var simulatedError: Error?

    func setRemoteFiles(for mountID: UUID, files: [String: String]) {
        lock.withLock {
            storage[mountID] = files
        }
    }

    func getRemoteFile(for mountID: UUID, relativePath: String) -> String? {
        lock.withLock {
            storage[mountID]?[relativePath]
        }
    }

    func fetchSnapshot(for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let (err, files) = lock.withLock {
            (simulatedError, storage[mount.id] ?? [:])
        }

        if let err {
            throw err
        }

        let now = Date().timeIntervalSince1970
        return files.keys.sorted().compactMap { relPath in
            guard let text = files[relPath] else { return nil }
            return RemoteFileEntry(relativePath: relPath, modificationTimestamp: now, content: text)
        }
    }

    func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
        let err: Error? = lock.withLock {
            if simulatedError == nil {
                var map = storage[mount.id] ?? [:]
                map[relativePath] = content
                storage[mount.id] = map
            }
            return simulatedError
        }

        if let err {
            throw err
        }
        return Date().timeIntervalSince1970
    }

    func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {
        let err: Error? = lock.withLock {
            if simulatedError == nil {
                storage[mount.id]?.removeValue(forKey: relativePath)
            }
            return simulatedError
        }

        if let err {
            throw err
        }
    }
}

