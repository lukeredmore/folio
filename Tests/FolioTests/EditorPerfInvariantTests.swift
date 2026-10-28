import AppKit
import XCTest
@testable import Folio

/// Work-count invariants for the live editor. Each test drives the production window with real
/// key events and asserts how much work the editor did, not how long it took, so results do not
/// depend on machine speed. Timing and scaling checks are in `EditorPerfScalingTests`.
@MainActor
final class EditorPerfInvariantTests: XCTestCase {
    /// Runs `body` with a fresh 200-line harness. Tests stay synchronous so nested run loops
    /// can drain the main dispatch queue, which they cannot do inside an async test.
    private func withHarness(_ body: (EditorHarness) throws -> Void) throws {
        let harness = try EditorHarness(lineCount: 200)
        defer { harness.tearDown() }
        try body(harness)
    }

    func testOneTypedCharacterRestylesAndParsesOnce() throws {
        try withHarness { harness in
            let paragraphLine = harness.middleParagraphLine
            harness.moveCursor(toLine: paragraphLine, column: .max)
            let firstBefore = harness.counters
            harness.type("a")
            let first = harness.counters.delta(since: firstBefore)

            let before = harness.counters
            let willChangeBefore = harness.objectWillChangeCount
            harness.type("b")
            let steady = harness.counters.delta(since: before)

            XCTAssertTrue(harness.lineText(paragraphLine).hasSuffix("ab"), "key events did not insert text")
            var report = PerfReport.values(steady)
            report["firstKey"] = PerfReport.values(first)
            report["objectWillChangePerKey"] = harness.objectWillChangeCount - willChangeBefore
            report["documentLines"] = 200
            PerfReport.record("oneKeystroke_200", report)

            XCTAssertEqual(first.restyleCount, 1, "first typed character must restyle once")
            XCTAssertEqual(first.parseCount, 1, "first typed character must parse once")
            XCTAssertEqual(steady.restyleCount, 1, "a typed character must restyle once")
            XCTAssertEqual(steady.parseCount, 1, "a typed character must parse once")
        }
    }

    func testTypingDoesNotPersistUntilAutosaveDelay() throws {
        try withHarness { harness in
            let paragraphLine = harness.middleParagraphLine
            harness.moveCursor(toLine: paragraphLine, column: .max)
            let before = harness.workspaceCounters
            var longestKeySeconds: TimeInterval = 0
            for character in "abcde fghij klmno pq" {
                let started = Date()
                harness.type(String(character))
                longestKeySeconds = max(longestKeySeconds, Date().timeIntervalSince(started))
            }
            let duringTyping = harness.workspaceCounters.delta(since: before)

            let delay = harness.viewModel.autoSaveDelay
            let saved = harness.waitUntil(timeout: delay + 5) {
                harness.workspaceCounters.delta(since: before).autosaveWriteCount >= 1
            }
            harness.drainUntilQuiet(quietPeriod: 0.25)
            let afterDelay = harness.workspaceCounters.delta(since: before)

            PerfReport.record(
                "typing20_persistence_200",
                [
                    "undoPersistDuringTyping": duringTyping.undoPersistCount,
                    "autosaveWritesDuringTyping": duringTyping.autosaveWriteCount,
                    "undoPersistAfterDelay": afterDelay.undoPersistCount,
                    "autosaveWritesAfterDelay": afterDelay.autosaveWriteCount,
                    "longestKeySeconds": longestKeySeconds,
                    "autoSaveDelaySeconds": delay
                ])

            XCTAssertLessThan(
                longestKeySeconds,
                delay,
                "a key took longer than the autosave delay, so the next check is void"
            )
            XCTAssertEqual(duringTyping.undoPersistCount, 0, "typing must not persist undo history per keystroke")
            XCTAssertEqual(duringTyping.autosaveWriteCount, 0, "typing must not write the file per keystroke")
            XCTAssertTrue(saved, "autosave did not run after the autosave delay")
            XCTAssertLessThanOrEqual(afterDelay.undoPersistCount, 1)
            XCTAssertLessThanOrEqual(afterDelay.autosaveWriteCount, 1)
        }
    }

    func testSelectionMoveWithinLineDoesNotRestyle() throws {
        try withHarness { harness in
            let paragraphLine = harness.middleParagraphLine
            harness.moveCursor(toLine: paragraphLine, column: 4)
            let before = harness.counters
            harness.press(.right)
            harness.press(.right)
            harness.press(.left)
            let delta = harness.counters.delta(since: before)
            PerfReport.record("selectionWithinLine_200", PerfReport.values(delta, keys: 3))
            let expected = harness.lineStart(paragraphLine) + 5
            let location = harness.textView.selectedRange().location
            XCTAssertEqual(location, expected, "arrow keys did not move the selection")
            XCTAssertEqual(delta.restyleCount, 0, "moving the cursor within a line must not restyle")
        }
    }

    func testCursorMoveToAnotherLineRestylesOnlyOldAndNewBlocks() throws {
        try withHarness { harness in
            let lines = harness.workspace.document.paragraphLines
            let from = lines[1]
            let to = lines[lines.count - 2]
            harness.moveCursor(toLine: from, column: 3)
            let before = harness.counters
            harness.moveCursor(toLine: to, column: 3)
            let delta = harness.counters.delta(since: before)
            let budget = harness.blockLength(containingLine: from) + harness.blockLength(containingLine: to)
            var report = PerfReport.values(delta)
            report["oldAndNewBlockCharacters"] = budget
            PerfReport.record("cursorMoveAcrossDocument_200", report)
            XCTAssertEqual(delta.restyleCount, 1, "moving the cursor to another line must restyle once")
            XCTAssertLessThanOrEqual(
                delta.charactersRestyled,
                budget,
                "a cursor move restyled \(delta.charactersRestyled) characters; the old and new blocks have \(budget)"
            )
        }
    }

    func testScrollingDoesNotRestyle() throws {
        try withHarness { harness in
            let clip = try XCTUnwrap(harness.textView.enclosingScrollView?.contentView)
            let startY = clip.bounds.origin.y
            let before = harness.counters
            for _ in 0..<5 {
                harness.scroll(by: 300)
            }
            harness.drainUntilQuiet(quietPeriod: 0.25)
            let delta = harness.counters.delta(since: before)
            PerfReport.record("scroll5_200", PerfReport.values(delta, keys: 5))
            XCTAssertGreaterThan(clip.bounds.origin.y, startY, "the editor did not scroll")
            XCTAssertEqual(delta.restyleCount, 0, "scrolling must not restyle")
        }
    }

    func testResizeBurstRestylesOnceAfterDebounce() throws {
        try withHarness { harness in
            let manual = ManualEditorScheduler()
            harness.coordinator.scheduler = manual.scheduler
            let startWidth = harness.window.frame.width
            let before = harness.counters
            for step in 1...30 {
                harness.resize(width: startWidth - CGFloat(step) * 10)
            }
            harness.drainUntilIdle()
            let duringBurst = harness.counters.delta(since: before)
            XCTAssertEqual(harness.window.frame.width, startWidth - 300, accuracy: 1)
            XCTAssertEqual(duringBurst.restyleCount, 0, "a resize burst must not restyle before the debounce fires")
            XCTAssertEqual(manual.liveCount, 1, "each resize step must replace the pending restyle")

            manual.flush()
            harness.drainUntilIdle()
            let delta = harness.counters.delta(since: before)
            PerfReport.record("resizeBurst30_200", PerfReport.values(delta))
            XCTAssertEqual(delta.restyleCount, 1, "a resize burst must restyle exactly once after the debounce")
        }
    }
}
