import AppKit
import XCTest
@testable import Folio

@MainActor
final class ViewportWidthRestyleTests: XCTestCase {

    /// A legacy vertical scroller narrows the clip view but not the scroll view frame (CI
    /// runners and "Show scroll bars: Always" use one). The editor must restyle at the
    /// narrower width, or text keeps wrapping at the old width.
    func testLegacyScrollerRestylesAtTheNarrowerWidth() throws {
        // Narrow, so the prose column follows the clip view width instead of its maximum.
        let harness = try EditorHarness(lineCount: 200, size: NSSize(width: 700, height: 700))
        defer { harness.tearDown() }
        let scrollView = try XCTUnwrap(harness.textView.enclosingScrollView)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.tile()
        harness.drainUntilQuiet(quietPeriod: 0.3)
        let frame = scrollView.frame
        let overlayWidth = harness.coordinator.currentContentWidth(for: harness.textView)
        XCTAssertEqual(harness.coordinator.lastContentWidth, overlayWidth, accuracy: 0.5)

        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        harness.drainUntilQuiet(quietPeriod: 0.3)

        let legacyWidth = harness.coordinator.currentContentWidth(for: harness.textView)
        XCTAssertEqual(scrollView.frame, frame, "Only the clip view changes width")
        XCTAssertLessThan(legacyWidth, overlayWidth - 1, "A legacy scroller must take width from the clip view")
        XCTAssertEqual(harness.coordinator.lastContentWidth, legacyWidth, accuracy: 0.5, "The editor must restyle at the new width")
        XCTAssertNil(RestyleEquivalenceOracle.firstMismatch(in: harness))
    }
}
