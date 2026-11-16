import AppKit
import SwiftUI
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

final class MarkdownAstAndTableTests: XCTestCase {

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
        XCTAssertEqual(
            firstRow.4.count, 3,
            "4 columns must produce 3 interior column dividers; pipes inside inline code, math, and escaped \\| must not split extra columns")
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
        XCTAssertEqual(
            activePara?.firstLineHeadIndent, inactivePara?.firstLineHeadIndent,
            "Active and inactive top-level list items must have identical firstLineHeadIndent")
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

    func testTabIndentedLinksCollapseExactSyntaxRanges() {
        let sample =
            "Active cursor line.\n"
            + "-\tSee [Guide][guide] and www.example.com\n"
            + "\tMore [Docs][guide] here\n\n"
            + "Paragraph first line\n"
            + "\t[TabPara][guide] and\t[MidTab][guide]\n\n"
            + "[guide]: https://example.com\n"
        let storage = NSTextStorage(string: sample)
        let theme = EditorTheme.daylight
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: theme,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let ns = sample as NSString
        for label in ["Guide", "Docs", "TabPara", "MidTab", "www.example.com"] {
            let range = ns.range(of: label)
            XCTAssertNotEqual(range.location, NSNotFound)
            for offset in 0..<range.length {
                let loc = range.location + offset
                XCTAssertNil(
                    storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: loc, effectiveRange: nil),
                    "Visible character in '\(label)' on tab-indented line must not be collapsed"
                )
                let color = storage.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
                XCTAssertEqual(color, theme.linkNSColor)
            }
        }

        for refToken in ["[Guide][guide]", "[Docs][guide]", "[TabPara][guide]", "[MidTab][guide]"] {
            let tokenRange = ns.range(of: refToken)
            XCTAssertNotEqual(tokenRange.location, NSNotFound)
            XCTAssertNotNil(
                storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: tokenRange.location, effectiveRange: nil),
                "Opening '[' of \(refToken) on tab-indented line must collapse"
            )
            let suffixLoc = NSMaxRange(tokenRange) - "][guide]".count
            XCTAssertNotNil(
                storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: suffixLoc, effectiveRange: nil),
                "Closing '][guide]' of \(refToken) on tab-indented line must collapse"
            )
        }
    }

    func testTableBodyRowsResolveReferenceLinksAutolinksAndPreserveColumnKern() {
        let sample = """
            Cursor on top line.

            | Section | Reference | Math |
            | :--- | :--- | :--- |
            | Intro | [Header Guide][guide] | $a + b$ |
            | Details | [Body Spec][spec] and www.example.com | $f[x][guide]$ |

            [guide]: https://example.com/guide
            [spec]: https://example.com/spec
            """
        let storage = NSTextStorage(string: sample)
        let theme = EditorTheme.daylight
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: theme,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        let ns = sample as NSString
        for linkedText in ["Header Guide", "Body Spec", "www.example.com"] {
            let range = ns.range(of: linkedText)
            XCTAssertNotEqual(range.location, NSNotFound)
            let fg = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            let underline = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int
            XCTAssertEqual(fg, theme.linkNSColor, "'\(linkedText)' in table body row must be styled as a link")
            XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
        }

        let bodySuffixRange = ns.range(of: "][spec]")
        XCTAssertNotNil(
            storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: bodySuffixRange.location, effectiveRange: nil),
            "Reference link trailing syntax in table body row must collapse when unselected"
        )

        let mathRefRange = ns.range(of: "[x][guide]")
        let mathUnderline = storage.attribute(.underlineStyle, at: mathRefRange.location, effectiveRange: nil) as? Int ?? 0
        XCTAssertEqual(mathUnderline, 0, "Reference-like brackets inside table inline math must not become links")

        let detailsRowRange = ns.lineRange(for: ns.range(of: "| Details |"))
        let leadingPipeKern = storage.attribute(.kern, at: detailsRowRange.location, effectiveRange: nil) as? CGFloat ?? 0
        let secondPipeLoc = ns.range(of: "| [Body Spec]", options: [], range: detailsRowRange).location
        let secondPipeKern = storage.attribute(.kern, at: secondPipeLoc, effectiveRange: nil) as? CGFloat ?? 0
        XCTAssertGreaterThan(leadingPipeKern, 8.0, "Leading pipe alignment kern on table body row must be preserved")
        XCTAssertGreaterThan(secondPipeKern, 8.0, "Second column pipe alignment kern before reference link must be preserved")
    }

    func testMultiLineReferenceImageAttachesHeightAndDecorationToOpeningLine() throws {
        let sample = """
            Cursor on line one.

            ![Multi-line alt
            caption text][hero]

            [hero]: https://example.com/hero.png
            """
        let storage = NSTextStorage(string: sample)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            prettyMode: true
        )

        let ns = sample as NSString
        let openingLineRange = ns.lineRange(for: ns.range(of: "![Multi-line alt"))
        let imageDec = try XCTUnwrap(
            analysis.decorations.first {
                if case .imageRendered = $0.kind { return true }
                return false
            }
        )
        XCTAssertEqual(imageDec.lineRange, openingLineRange, "Multi-line reference image decoration must attach to the opening '![' line")
        let openingPara = storage.attribute(.paragraphStyle, at: openingLineRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThanOrEqual(openingPara?.minimumLineHeight ?? 0, 52.0)
    }
}
