import AppKit
import XCTest
@testable import Folio

@MainActor
final class PageLayoutAndPrintTests: XCTestCase {

    private let sample = """
    # Heading

    A prose paragraph that is long enough to wrap onto a second line when the column is narrow.

    - A list item with enough words to wrap as well.

    > A quoted line.

    ```swift
    let code = 1
    ```

    | A | B |
    |---|---|
    | 1 | 2 |
    """

    private func alignment(at text: String, in storage: NSTextStorage) -> NSTextAlignment? {
        let location = (storage.string as NSString).range(of: text).location
        return (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.alignment
    }

    private func style(_ alignment: NSTextAlignment) -> NSTextStorage {
        let storage = NSTextStorage(string: sample + "\n\nEnd")
        MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: (storage.string as NSString).length, length: 0),
            containerWidth: 600,
            textAlignment: alignment
        )
        return storage
    }

    func testJustifyAppliesToProseOnly() {
        let storage = style(.justified)
        XCTAssertEqual(alignment(at: "A prose paragraph", in: storage), .justified)
        XCTAssertEqual(alignment(at: "A list item", in: storage), .justified)
        XCTAssertEqual(alignment(at: "A quoted line", in: storage), .justified)
        XCTAssertNotEqual(alignment(at: "Heading", in: storage), .justified)
        XCTAssertNotEqual(alignment(at: "let code", in: storage), .justified)
        XCTAssertNotEqual(alignment(at: "| 1 |", in: storage), .justified)
    }

    func testLeftAlignmentLeavesParagraphsNatural() {
        let storage = style(.natural)
        XCTAssertEqual(alignment(at: "A prose paragraph", in: storage), .natural)
    }

    func testSettingsPersist() {
        let defaults = isolatedDefaults()
        let vm = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(vm.textAlignment, .left)
        XCTAssertEqual(vm.printPaperSize, .letter)
        vm.textAlignment = .justified
        vm.printPaperSize = .a4
        let reloaded = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(reloaded.textAlignment, .justified)
        XCTAssertEqual(reloaded.printPaperSize, .a4)
    }

    func testPrintViewUsesPaperWidthAndRendersEverything() throws {
        let vm = makeIsolatedViewModel()
        let diagram = "flowchart LR\n    Seed\(UUID().uuidString.prefix(6)) --> Bed"
        vm.markdownText = "# Plan\n\nSome **bold** words.\n\n```mermaid\n\(diagram)\n```\n\n" + sample

        let view = vm.makePrintView(paper: .a4)
        XCTAssertEqual(view.frame.width, PrintPaperSize.a4.printableWidth, accuracy: 0.5)
        XCTAssertEqual(view.textContainer?.containerSize.width ?? 0, PrintPaperSize.a4.printableWidth, accuracy: 0.5)
        XCTAssertGreaterThan(view.frame.height, 300)

        let storage = try XCTUnwrap(view.textStorage)
        let marker = (storage.string as NSString).range(of: "**bold").location
        let markerFont = storage.attribute(.font, at: marker, effectiveRange: nil) as? NSFont
        XCTAssertLessThanOrEqual(markerFont?.pointSize ?? 99, 0.2, "Print renders every line, so syntax is folded")
        XCTAssertNotNil(
            DiagramImageRenderer.shared.image(for: DiagramImageRenderer.Key(kind: .mermaid(isDark: false), source: diagram)),
            "Diagrams are rendered before printing"
        )
        XCTAssertTrue(view.lineDecorations.contains { if case .mermaidBlockRendered = $0.kind { return true }; return false })
    }

    func testDarkThemesPrintWithTheLightTheme() {
        let vm = makeIsolatedViewModel()
        vm.theme = .midnight
        XCTAssertTrue(vm.theme.isDark)
        XCTAssertFalse(vm.printTheme.isDark)
        XCTAssertEqual(vm.printTheme.typography, vm.typography)
    }

    func testPageBreakMovesAboveADiagramCard() throws {
        let card = NSRect(x: 0, y: 500, width: 400, height: 200)
        let page: CGFloat = 720
        XCTAssertEqual(HybridMarkdownTextView.pageBottom(600, pageTop: 0, pageHeight: page, limit: 0, avoiding: [card]), 500)
        XCTAssertEqual(HybridMarkdownTextView.pageBottom(480, pageTop: 0, pageHeight: page, limit: 0, avoiding: [card]), 480, "Breaks outside cards are unchanged")
        XCTAssertEqual(HybridMarkdownTextView.pageBottom(600, pageTop: 0, pageHeight: page, limit: 550, avoiding: [card]), 600, "The break never moves above the limit")
        let tallCard = NSRect(x: 0, y: 100, width: 400, height: 900)
        XCTAssertEqual(HybridMarkdownTextView.pageBottom(600, pageTop: 0, pageHeight: page, limit: 0, avoiding: [tallCard]), 600, "A card taller than a page is split")

        let vm = makeIsolatedViewModel()
        vm.markdownText = "# Plan\n\nIntro.\n\n```mermaid\nflowchart LR\n    Seed --> Sprout --> Bed\n```\n\nAfter."
        let view = vm.makePrintView(paper: .letter)
        let printed = try XCTUnwrap(view.unbreakableBlockRects().first)
        var bottom = printed.midY
        view.adjustPageHeightNew(&bottom, top: 0, bottom: printed.midY, limit: 0)
        XCTAssertLessThanOrEqual(bottom, printed.minY + 0.5, "The print view never breaks inside the diagram card")
    }

    func testDocumentPageLayoutExtractsLaTeXGeometryAndDocumentClass() {
        let tex = """
        \\documentclass[11pt,a4paper,landscape]{article}
        \\usepackage[margin=1in,top=1.5in,bottom=2.54cm]{geometry}
        \\raggedright
        \\begin{document}
        Hello world.
        \\end{document}
        """
        let doc = DocumentPageLayout.extract(from: tex, fileURL: URL(fileURLWithPath: "/tmp/doc.tex"))
        XCTAssertFalse(doc.isEmpty)
        XCTAssertEqual(doc.paperSize, .a4)
        XCTAssertEqual(doc.orientation, .landscape)
        XCTAssertEqual(doc.baseFontSizePoints ?? 0, 11.0, accuracy: 0.01)
        XCTAssertEqual(doc.textAlignment, .left)
        XCTAssertEqual(doc.topMargin ?? 0, 108.0, accuracy: 0.5)
        XCTAssertEqual(doc.bottomMargin ?? 0, 72.0, accuracy: 0.5)
        XCTAssertEqual(doc.leftMargin ?? 0, 72.0, accuracy: 0.5)
        XCTAssertEqual(doc.rightMargin ?? 0, 72.0, accuracy: 0.5)

        let resolved = doc.resolve(
            defaultPaper: .letter,
            defaultOrientation: .portrait,
            defaultMargins: .default
        )
        XCTAssertEqual(resolved.paperSize, .a4)
        XCTAssertEqual(resolved.orientation, .landscape)
        // A4 landscape width is 841.89 pt; minus 1in (72pt) left & right = 697.89 pt
        XCTAssertEqual(resolved.printableWidth, 841.89 - 144.0, accuracy: 0.5)
    }

    func testDocumentPageLayoutExtractsMarkdownFrontmatterAndComments() {
        let md = """
        ---
        title: Quarterly Report
        paper: legal
        orientation: landscape
        margin: 1in
        margin-left: 1.25in
        fontsize: 12pt
        align: justify
        ---

        # Quarterly Report

        Body paragraph.
        """
        let doc = DocumentPageLayout.extract(from: md, fileURL: URL(fileURLWithPath: "/tmp/report.md"))
        XCTAssertFalse(doc.isEmpty)
        XCTAssertEqual(doc.paperSize, .legal)
        XCTAssertEqual(doc.orientation, .landscape)
        XCTAssertEqual(doc.topMargin ?? 0, 72.0, accuracy: 0.5)
        XCTAssertEqual(doc.leftMargin ?? 0, 90.0, accuracy: 0.5)
        XCTAssertEqual(doc.baseFontSizePoints ?? 0, 12.0, accuracy: 0.1)
        XCTAssertEqual(doc.textAlignment, .justified)
        XCTAssertNotNil(doc.metadataRange)

        let commentMd = """
        <!-- page: paper=a4, margin=0.5in -->
        # Notes
        """
        let commentDoc = DocumentPageLayout.extract(from: commentMd, fileURL: URL(fileURLWithPath: "/tmp/notes.md"))
        XCTAssertEqual(commentDoc.paperSize, .a4)
        XCTAssertEqual(commentDoc.leftMargin ?? 0, 36.0, accuracy: 0.5)
    }

    func testPrintViewRespectsLaTeXDocumentGeometryAndCollapsesPreamble() throws {
        let vm = makeIsolatedViewModel()
        vm.currentFileURL = try makeTemporaryDirectory().appendingPathComponent("paper.tex")
        vm.markdownText = """
        \\documentclass[11pt,a4paper]{article}
        \\usepackage[margin=1in]{geometry}
        \\begin{document}
        \\section{Introduction}
        Let $x \\in \\mathbb{R}$.
        \\begin{equation}
        E = mc^2
        \\end{equation}
        \\end{document}
        """

        let resolved = vm.resolvedPrintPageLayout()
        XCTAssertEqual(resolved.paperSize, .a4)
        XCTAssertEqual(resolved.margins, .normal)

        let printInfo = vm.configuredPrintInfo(for: resolved)
        XCTAssertEqual(printInfo.paperSize.width, PrintPaperSize.a4.size.width, accuracy: 0.5)
        XCTAssertEqual(printInfo.topMargin, 72.0, accuracy: 0.5)
        XCTAssertEqual(printInfo.leftMargin, 72.0, accuracy: 0.5)

        let view = vm.makePrintView()
        let expectedWidth = PrintPaperSize.a4.size.width - 144.0
        XCTAssertEqual(view.frame.width, expectedWidth, accuracy: 0.5)
        XCTAssertFalse(
            view.lineDecorations.contains { if case .latexPreambleCard = $0.kind { return true }; return false },
            "Print view should strip the interactive preamble banner card"
        )
        XCTAssertTrue(
            view.lineDecorations.contains { if case .mathBlockRendered = $0.kind { return true }; return false },
            "Print view should include rendered LaTeX equations"
        )
        let pdfData = view.dataWithPDF(inside: view.bounds)
        XCTAssertGreaterThan(pdfData.count, 500, "Print view should produce valid PDF data with rendered decorations")
    }
}
