import AppKit
import XCTest
@testable import Folio

@MainActor
final class DiagramExpandTests: XCTestCase {

    private func makeEditor(_ markdown: String) -> HybridMarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), textContainer: container)
        textView.textContainerInset = NSSize(width: 100, height: 20)
        textView.proseColumnWidth = 700
        textView.string = markdown
        let style = {
            MarkdownLiveStyler.applyStyles(
                to: storage, theme: .daylight, sourceCodeMode: false, focusMode: false,
                selectedRange: NSRange(location: (storage.string as NSString).length, length: 0), containerWidth: 700
            )
        }
        _ = style()
        _ = DiagramImageRenderer.shared.waitUntilIdle()
        textView.lineDecorations = style().decorations
        layoutManager.ensureLayout(for: container)
        return textView
    }

    func testExpandButtonOpensTheRenderedDiagram() throws {
        let source = "flowchart LR\n    Seed\(UUID().uuidString.prefix(6)) --> Bed"
        let textView = makeEditor("# Plan\n\n```mermaid\n\(source)\n```\n\nAfter.\n\n")
        let range = try XCTUnwrap(
            textView.lineDecorations.compactMap { decoration -> NSRange? in
                if case let .mermaidBlockRendered(_, fullBlockRange, _) = decoration.kind { return fullBlockRange }
                return nil
            }.first)
        let card = try XCTUnwrap(textView.diagramCardRect(for: range))
        let button = HybridMarkdownTextView.diagramExpandButtonRect(in: card)
        XCTAssertTrue(card.contains(button), "The button sits inside the card")

        let diagram = try XCTUnwrap(textView.expandableDiagram(at: NSPoint(x: button.midX, y: button.midY)))
        XCTAssertEqual(diagram.source, source)
        XCTAssertGreaterThan(diagram.image.size.width, 0)
        XCTAssertNil(textView.expandableDiagram(at: NSPoint(x: card.midX, y: card.midY)), "Only the button opens the sheet")
    }

    func testZoomControllerFitsAndClamps() {
        let image = NSImage(size: NSSize(width: 2000, height: 1000))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.documentView = DiagramCanvasView(image: image)
        let controller = DiagramZoomController()
        controller.scrollView = scrollView

        controller.fit()
        let fitted = scrollView.magnification
        XCTAssertLessThan(fitted, 1)
        XCTAssertLessThanOrEqual(2080 * fitted, scrollView.contentSize.width + 1, "Fit shows the whole width")
        XCTAssertEqual(controller.magnification, fitted, accuracy: 0.001)

        controller.zoom(by: 1000)
        XCTAssertEqual(scrollView.magnification, 8, accuracy: 0.001, "Zoom clamps at the maximum")
        controller.setMagnification(0.01)
        XCTAssertEqual(scrollView.magnification, 0.1, accuracy: 0.001, "Zoom clamps at the minimum")
    }
}
