import AppKit
import XCTest
@testable import Folio

@MainActor
final class DrawCullingTests: XCTestCase {

    private func makeTextView(_ text: String) -> HybridMarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), textContainer: container)
        textView.string = text
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 700
        )
        textView.lineDecorations = analysis.decorations
        return textView
    }

    func testCodeFenceSpanCoversWholeBlock() {
        let text = "Intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nOutro"
        let textView = makeTextView(text)
        guard let startIndex = textView.lineDecorations.firstIndex(where: {
            if case .codeFenceStart = $0.kind { return true }
            return false
        }) else {
            return XCTFail("Expected a code fence decoration")
        }
        let span = textView.decorationSpan(at: startIndex)
        let ns = text as NSString
        XCTAssertEqual(span.location, ns.range(of: "```swift").location)
        XCTAssertGreaterThanOrEqual(NSMaxRange(span), NSMaxRange(ns.range(of: "```\n\nOutro")) - "\n\nOutro".count)
    }

    func testVisibleRangeExcludesTextFarBelowTheDirtyRect() {
        let lines = (0..<2000).map { "Paragraph \($0) with some words." }
        let text = lines.joined(separator: "\n\n")
        let textView = makeTextView(text)
        guard let visible = textView.visibleDecorationCharacterRange(for: NSRect(x: 0, y: 0, width: 760, height: 600)) else {
            return XCTFail("Expected a visible range")
        }
        let farBelow = (text as NSString).range(of: "Paragraph 1500 ")
        XCTAssertEqual(visible.location, 0)
        XCTAssertLessThan(NSMaxRange(visible), farBelow.location, "Off-screen decorations must be skipped")
    }

    func testSpanTouchRules() {
        let visible = NSRange(location: 100, length: 50)
        XCTAssertTrue(HybridMarkdownTextView.decorationSpan(NSRange(location: 90, length: 20), touches: visible))
        XCTAssertFalse(HybridMarkdownTextView.decorationSpan(NSRange(location: 150, length: 5), touches: visible))
        XCTAssertFalse(HybridMarkdownTextView.decorationSpan(NSRange(location: 40, length: 60), touches: visible))
        XCTAssertTrue(HybridMarkdownTextView.decorationSpan(NSRange(location: 120, length: 0), touches: visible))
    }

    func testCodeFenceCardStillDrawsWhenItsStartIsAboveTheDirtyRect() throws {
        let body = (0..<80).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let text = "# Title\n\n```swift\n\(body)\n```\n\nAfter."
        let textView = makeTextView(text)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.frame.size.height = (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0) + 100

        // A dirty rect in the middle of the fence, far below its opening line.
        let dirty = NSRect(x: 0, y: 900, width: 760, height: 200)
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: dirty))
        textView.cacheDisplay(in: dirty, to: rep)
        let sample = try XCTUnwrap(rep.colorAt(x: Int(textView.textContainerOrigin.x) + 4, y: 100)?.usingColorSpace(.sRGB))
        let codeBackground = try XCTUnwrap(EditorTheme.daylight.codeBackgroundNSColor.usingColorSpace(.sRGB))
        XCTAssertEqual(sample.redComponent, codeBackground.redComponent, accuracy: 0.02, "Code fence card must draw under its visible body")
        XCTAssertEqual(sample.blueComponent, codeBackground.blueComponent, accuracy: 0.02)
    }
}
