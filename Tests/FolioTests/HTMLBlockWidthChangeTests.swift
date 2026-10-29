import AppKit
import XCTest
@testable import Folio

/// HTML block heights are cached per column width, so a width change must cache the measured
/// height again, also when the height stays the same.
@MainActor
final class HTMLBlockWidthChangeTests: XCTestCase {
    override func tearDown() {
        HTMLBlockLayoutCache.shared.removeAll()
        super.tearDown()
    }

    func testBlockReservesItsMeasuredHeightAfterAWidthChange() throws {
        let harness = try EditorHarness(workspace: PerfFixtures.makeWorkspace(copyingExample: "html_blocks_showcase.md"))
        defer { harness.tearDown() }
        let textView = harness.textView
        let tableStart = (textView.string as NSString).range(of: "<table>").location
        let table = try XCTUnwrap(textView.renderedHTMLBlocks().first { $0.range.location == tableStart })
        textView.scrollRangeToVisible(table.range)
        harness.settleBackgroundWork()
        let before = try XCTUnwrap(textView.htmlBlockOverlays.first { $0.blockRange.location == tableStart })
        let height = try XCTUnwrap(before.measuredHeight)
        let widthBefore = before.layoutWidth
        // Only a measurement at the new width can fill the cache.
        HTMLBlockLayoutCache.shared.removeAll()

        harness.resize(width: harness.window.frame.width + 1)
        harness.settleBackgroundWork()

        let overlay = try XCTUnwrap(textView.htmlBlockOverlays.first { $0.blockRange.location == tableStart })
        XCTAssertNotEqual(overlay.layoutWidth, widthBefore, "the column width must change")
        XCTAssertEqual(try XCTUnwrap(overlay.measuredHeight), height, accuracy: 0.5, "the table height must stay the same")
        let key = HTMLBlockLayoutCache.key(source: overlay.source, width: overlay.layoutWidth, style: overlay.style)
        XCTAssertEqual(HTMLBlockLayoutCache.shared.height(for: key), height, "the height must be cached for the new width")
        XCTAssertEqual(overlay.frame.height, height, accuracy: 1.0, "the hidden lines must reserve the measured height")
    }
}
