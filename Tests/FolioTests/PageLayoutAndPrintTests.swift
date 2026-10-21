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
        let suite = "com.folio.tests.page.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        XCTAssertEqual(vm.textAlignment, .left)
        XCTAssertEqual(vm.printPaperSize, .letter)
        vm.textAlignment = .justified
        vm.printPaperSize = .a4
        let reloaded = EditorWorkspaceViewModel(userDefaults: defaults)
        XCTAssertEqual(reloaded.textAlignment, .justified)
        XCTAssertEqual(reloaded.printPaperSize, .a4)
    }

    func testPrintViewUsesPaperWidthAndRendersEverything() throws {
        let suite = "com.folio.tests.print.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
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
        let suite = "com.folio.tests.printtheme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
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

        let suite = "com.folio.tests.paginate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.markdownText = "# Plan\n\nIntro.\n\n```mermaid\nflowchart LR\n    Seed --> Sprout --> Bed\n```\n\nAfter."
        let view = vm.makePrintView(paper: .letter)
        let printed = try XCTUnwrap(view.unbreakableBlockRects().first)
        var bottom = printed.midY
        view.adjustPageHeightNew(&bottom, top: 0, bottom: printed.midY, limit: 0)
        XCTAssertLessThanOrEqual(bottom, printed.minY + 0.5, "The print view never breaks inside the diagram card")
    }
}
