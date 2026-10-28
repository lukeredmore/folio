import AppKit
import XCTest
@testable import Folio

/// The incremental restyle fast path and input-method composition, through the real editor.
@MainActor
final class IncrementalRestyleTests: XCTestCase {
    private func withHarness(_ body: (EditorHarness) throws -> Void) throws {
        let harness = try EditorHarness(lineCount: 200)
        defer { harness.tearDown() }
        try body(harness)
    }

    func testTypingInsideParagraphDoesNotFallBackToFullRestyle() throws {
        try withHarness { harness in
            let line = harness.middleParagraphLine
            harness.moveCursor(toLine: line, column: 10)
            let before = harness.counters
            harness.type("abc def")
            harness.pressBackspace()
            harness.pressReturn()
            harness.type("next line")
            let delta = harness.counters.delta(since: before)

            XCTAssertGreaterThanOrEqual(delta.restyleCount, 17, "each key must restyle")
            XCTAssertEqual(
                delta.fullRangeRestyleCount,
                0,
                "typing in a paragraph fell back to a full restyle: \(String(describing: harness.coordinator.lastFullRestyleReason))"
            )
            XCTAssertNil(harness.coordinator.lastFullRestyleReason)
            XCTAssertNil(RestyleEquivalenceOracle.firstMismatch(in: harness))
        }
    }

    /// `setMarkedText` changes the selection, and in focus mode every selection change restyles.
    /// Without the composition check, a composition and its commit restyle three times.
    func testMarkedTextDefersRestyleUntilUnmarkText() throws {
        try withHarness { harness in
            harness.viewModel.focusMode = true
            harness.drainUntilIdle()
            let line = harness.middleParagraphLine
            harness.moveCursor(toLine: line, column: .max)
            let before = harness.counters
            harness.textView.setMarkedText(
                "ka",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            harness.drainUntilIdle()
            let composing = harness.counters.delta(since: before)

            XCTAssertTrue(harness.textView.hasMarkedText(), "setMarkedText did not start a composition")
            XCTAssertTrue(harness.lineText(line).hasSuffix("ka"), "marked text was not inserted")
            XCTAssertEqual(composing.restyleCount, 0, "the editor restyled during input-method composition")

            harness.textView.unmarkText()
            harness.drainUntilIdle()
            let committed = harness.counters.delta(since: before)

            XCTAssertFalse(harness.textView.hasMarkedText())
            XCTAssertEqual(committed.restyleCount, 1, "unmarkText must restyle the composed text once")
            XCTAssertNil(RestyleEquivalenceOracle.firstMismatch(in: harness))
        }
    }
}
