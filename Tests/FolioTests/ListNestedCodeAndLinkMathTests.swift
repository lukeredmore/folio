import AppKit
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

final class ListNestedCodeAndLinkMathTests: XCTestCase {

    private func style(_ sample: String) -> (NSTextStorage, MarkdownDocumentAnalysis) {
        let storage = NSTextStorage(string: sample)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: (sample as NSString).length, length: 0)
        )
        return (storage, analysis)
    }

    private func inlineMath(_ analysis: MarkdownDocumentAnalysis) -> [String] {
        analysis.decorations.compactMap {
            if case .inlineMathRendered(let latex, _, _, _) = $0.kind { return latex }
            return nil
        }
    }

    func testDollarSignsInsideLinkDestinationsDoNotRenderMath() {
        let url = "https://console.aws.amazon.com/cloudwatch/home#logsV2:logs-insights$3FqueryDetail$3D~(end~0)"
        let (_, analysis) = style("2. Find the errors: [errors (Prod)](\(url)) · [Beta](\(url)) for $x$.\n\nTail\n")
        XCTAssertEqual(inlineMath(analysis), ["x"], "`$` in a link URL must stay literal; math outside the link renders")
    }

    func testDollarFollowedByDigitDoesNotCloseMath() {
        let (_, analysis) = style("Costs $5 and $10 today, but $E = mc^2$ renders.\n\nTail\n")
        XCTAssertEqual(inlineMath(analysis), ["E = mc^2"])
    }

    func testFencedCodeInListItemIndentsToItemTextAndHidesContainerIndent() {
        let sample = "1. Read the messages:\n   ```\n   aws sqs receive-message \\\n     --queue-url https://example.com/queue\n   ```\n\nTail\n"
        let (storage, _) = style(sample)
        let ns = sample as NSString

        let itemText = ns.range(of: "Read the messages")
        let itemPara = storage.attribute(.paragraphStyle, at: itemText.location, effectiveRange: nil) as? NSParagraphStyle
        let itemIndent = itemPara?.headIndent ?? 0
        XCTAssertGreaterThan(itemIndent, 0)

        let body = ns.range(of: "   aws sqs")
        let bodyPara = storage.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(bodyPara?.firstLineHeadIndent ?? 0, itemIndent + 14.0, accuracy: 0.5)
        let containerFg = storage.attribute(.foregroundColor, at: body.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(containerFg?.alphaComponent ?? 1.0, 0.0, accuracy: 0.001, "List container indent should collapse")
        let codeFg = storage.attribute(.foregroundColor, at: body.location + 3, effectiveRange: nil) as? NSColor
        XCTAssertGreaterThan(codeFg?.alphaComponent ?? 0.0, 0.5, "Code text should stay visible")

        let continuation = ns.range(of: "     --queue-url")
        let contPara = storage.attribute(.paragraphStyle, at: continuation.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(contPara?.headIndent ?? 0, contPara?.firstLineHeadIndent ?? 0, "Wrapped rows hang under the code's own indent")

        let fence = ns.range(of: "   ```")
        let fencePara = storage.attribute(.paragraphStyle, at: fence.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(fencePara?.firstLineHeadIndent ?? 0, itemIndent + 14.0, accuracy: 0.5)
    }

    func testTopLevelFencedCodeKeepsDefaultIndent() {
        let sample = "```\nlet x = 1\n```\n\nTail\n"
        let (storage, _) = style(sample)
        let body = (sample as NSString).range(of: "let x")
        let para = storage.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(para?.firstLineHeadIndent ?? 0, 14.0, accuracy: 0.01)
        XCTAssertEqual(para?.headIndent ?? 0, 14.0, accuracy: 0.01)
    }

    func testAstLinksAndAutolinksInsideInlineMathAreSkipped() {
        let sample = """
            Active math $f[x][guide]$ and $https://example.com/math$ on cursor line.
            Inactive math $g[y][guide]$ and $www.example.com$ alongside [Real Guide][guide].

            [guide]: https://example.com/guide
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
        for mathToken in ["[x][guide]", "https://example.com/math", "[y][guide]", "www.example.com"] {
            let range = ns.range(of: mathToken)
            XCTAssertNotEqual(range.location, NSNotFound)
            let underline = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            XCTAssertEqual(underline, 0, "\(mathToken) inside $...$ must not be underlined as a cmark link/autolink")
        }

        let inactiveMathRange = ns.range(of: "$g[y][guide]$")
        XCTAssertNotNil(
            storage.attribute(MarkdownLiveStyler.inlineMathSpanAttributeKey, at: inactiveMathRange.location, effectiveRange: nil)
        )
        let mathKern = storage.attribute(.kern, at: inactiveMathRange.location, effectiveRange: nil) as? CGFloat ?? 0
        XCTAssertGreaterThan(mathKern, 4.0, "Inactive inline math box kern must remain intact")

        let realGuideRange = ns.range(of: "Real Guide")
        let realGuideColor = storage.attribute(.foregroundColor, at: realGuideRange.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(realGuideColor, theme.linkNSColor)
    }

    func testLinkReferenceDefinitionCaptureGroupsAndPrecedenceBeforeHorizontalRule() {
        let sample = """
            Cursor on line one.

            [ref]: https://example.com/path "Link Title"
            ---
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

        XCTAssertTrue(analysis.headings.isEmpty, "[ref]: url followed by --- must not be styled as a Setext H2")
        XCTAssertTrue(analysis.decorations.contains(where: { $0.kind == .horizontalRule }))

        let ns = sample as NSString
        let prefixRange = ns.range(of: "[ref]:")
        let urlRange = ns.range(of: "https://example.com/path")
        let titleRange = ns.range(of: #""Link Title""#)

        let prefixUnderline = storage.attribute(.underlineStyle, at: prefixRange.location, effectiveRange: nil) as? Int ?? 0
        XCTAssertEqual(prefixUnderline, 0)

        let spaceAfterColonUnderline = storage.attribute(.underlineStyle, at: NSMaxRange(prefixRange), effectiveRange: nil) as? Int ?? 0
        XCTAssertEqual(spaceAfterColonUnderline, 0, "Whitespace between [ref]: and URL must not be underlined")

        for offset in [0, 1, urlRange.length - 1] {
            let loc = urlRange.location + offset
            let underline = storage.attribute(.underlineStyle, at: loc, effectiveRange: nil) as? Int
            let fg = storage.attribute(.foregroundColor, at: loc, effectiveRange: nil) as? NSColor
            XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue, "Entire URL including leading characters must be underlined")
            XCTAssertEqual(fg, theme.linkNSColor.withAlphaComponent(0.75))
        }

        let titleUnderline = storage.attribute(.underlineStyle, at: titleRange.location, effectiveRange: nil) as? Int ?? 0
        XCTAssertEqual(titleUnderline, 0)
    }
}
