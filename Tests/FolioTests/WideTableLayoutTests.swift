import AppKit
import XCTest
@testable import Folio

@MainActor
final class WideTableLayoutTests: XCTestCase {

    private let column: CGFloat = 600

    private func table(columns: Int, words: Int) -> String {
        let header = "| " + (0..<columns).map { "Column \($0)" }.joined(separator: " | ") + " |"
        let separator = "|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|"
        let rows = (0..<3).map { r in
            "| " + (0..<columns).map { c in "Cell \(r).\(c) " + String(repeating: "seed ", count: words) }.joined(separator: " | ") + " |"
        }
        return ([header, separator] + rows).joined(separator: "\n")
    }

    /// Text view configured like the editor: centered column, no horizontal resizing.
    private func makeEditor(_ markdown: String, canvasWidth: CGFloat) -> HybridMarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = WideBlockLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(containerSize: NSSize(width: column, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: canvasWidth, height: 800), textContainer: container)
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: (canvasWidth - column) / 2, height: 20)
        textView.string = markdown
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: column
        )
        textView.lineDecorations = analysis.decorations
        layoutManager.ensureLayout(for: container)
        return textView
    }

    private func fragment(of text: String, in textView: HybridMarkdownTextView) -> NSRect {
        let location = (textView.string as NSString).range(of: text).location
        let glyph = textView.layoutManager!.glyphIndexForCharacter(at: location)
        return textView.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    func testColumnStaysAtTheInsetWhenATableIsWide() {
        let textView = makeEditor("# Title\n\n" + table(columns: 6, words: 3), canvasWidth: 1400)
        XCTAssertEqual(textView.textContainerOrigin.x, 400, "The column must stay centered")
        XCTAssertEqual(textView.frame.width, 1400)
    }

    func testTableWiderThanTheColumnIsCenteredOnIt() {
        let textView = makeEditor("Intro\n\n" + table(columns: 5, words: 2), canvasWidth: 1600)
        let rowFragment = fragment(of: "Cell 0.0", in: textView)
        let tableWidth = rowFragment.width
        XCTAssertGreaterThan(tableWidth, column)
        XCTAssertEqual(rowFragment.minX, -floor((tableWidth - column) / 2), accuracy: 1)
        XCTAssertEqual(fragment(of: "Intro", in: textView).minX, 0, "Prose stays in the column")
        XCTAssertTrue(textView.overflowingTables.isEmpty)
    }

    func testTableWiderThanTheCanvasIsPinnedAndScrollsOnItsOwn() throws {
        let canvas: CGFloat = 1000
        let textView = makeEditor("Intro\n\n" + table(columns: 12, words: 3), canvasWidth: canvas)
        let table = try XCTUnwrap(textView.overflowingTables.first)
        let margin = HybridMarkdownTextView.wideTableCanvasMargin
        XCTAssertEqual(fragment(of: "Cell 0.0", in: textView).minX, -(textView.textContainerOrigin.x - margin), accuracy: 0.5)

        let rowPoint = NSPoint(x: 100, y: try XCTUnwrap(textView.tableRect(for: table.range)).midY)
        XCTAssertTrue(textView.scrollOverflowingTable(at: rowPoint, by: -120))
        XCTAssertEqual(fragment(of: "Cell 0.0", in: textView).minX, -(textView.textContainerOrigin.x - margin) - 120, accuracy: 0.5)

        textView.scrollOverflowingTable(at: rowPoint, by: -1_000_000)
        XCTAssertEqual(textView.tableScrollOffsets[table.range.location], table.maxScroll, "Scrolling clamps at the table's end")
        textView.scrollOverflowingTable(at: rowPoint, by: 1_000_000)
        XCTAssertEqual(textView.tableScrollOffsets[table.range.location], 0)

        let introPoint = NSPoint(x: 500, y: try XCTUnwrap(textView.tableRect(for: NSRange(location: 0, length: 5))).midY)
        XCTAssertFalse(textView.scrollOverflowingTable(at: introPoint, by: -50), "Scrolling outside a table is left to the canvas")
    }

    func testTextLeftOfTheColumnIsDrawn() throws {
        let textView = makeEditor("Intro\n\n" + table(columns: 6, words: 4), canvasWidth: 1500)
        textView.backgroundColor = .white
        let rowFragment = fragment(of: "Cell 1.0", in: textView)
        XCTAssertLessThan(rowFragment.minX, -40)
        let strip = NSRect(
            x: textView.textContainerOrigin.x + rowFragment.minX,
            y: textView.textContainerOrigin.y + rowFragment.minY,
            width: -rowFragment.minX,
            height: rowFragment.height
        )
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        var darkPixels = 0
        for x in stride(from: Int(strip.minX * scale), to: Int(strip.maxX * scale), by: 2) {
            for y in stride(from: Int(strip.minY * scale), to: Int(strip.maxY * scale), by: 2) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.brightnessComponent < 0.5 {
                    darkPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(darkPixels, 20, "Cell text left of the column must be drawn")
    }
}
