import AppKit
import XCTest
@testable import Folio

/// Run loop draining and waits for background work in `EditorHarness`. The waits fail the test
/// on timeout, so unfinished work is reported where it happened instead of as a later mismatch.
extension EditorHarness {
    /// Runs the main run loop in 1 ms slices until no work counter changes for
    /// `stableIterations` slices in a row, then displays the window.
    func drainUntilIdle(stableIterations: Int = 5, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = fingerprint
        var stable = 0
        while stable < stableIterations && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let current = fingerprint
            if current == last {
                stable += 1
            } else {
                stable = 0
                last = current
            }
        }
        window.displayIfNeeded()
    }

    /// Like `drainUntilIdle`, but requires `quietPeriod` seconds without counter changes, so
    /// debounced work (resize restyle) has run.
    func drainUntilQuiet(quietPeriod: TimeInterval, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = fingerprint
        var quietSince = Date()
        while Date().timeIntervalSince(quietSince) < quietPeriod && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            let current = fingerprint
            if current != last {
                last = current
                quietSince = Date()
            }
        }
        window.displayIfNeeded()
    }

    /// Polls `condition` while running the main run loop. Returns false on timeout.
    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        return true
    }

    /// Like `waitUntil`, but fails the test when `condition` is still false after `timeout`.
    func require(
        _ expectation: @autoclosure () -> String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        if !waitUntil(timeout: timeout, condition) {
            XCTFail("Timed out after \(timeout) s waiting for \(expectation())", file: file, line: line)
        }
    }

    /// True when the last restyle used the current content width and no resize restyle waits.
    var isStyledAtCurrentWidth: Bool {
        coordinator.pendingResizeRestyleWorkItem == nil
            && abs(coordinator.lastContentWidth - coordinator.currentContentWidth(for: textView)) <= 0.5
    }

    private var contentWidthState: String {
        let pending = coordinator.pendingResizeRestyleWorkItem == nil ? "none" : "one"
        return
            "content width \(coordinator.currentContentWidth(for: textView)), last restyle at "
            + "\(coordinator.lastContentWidth), pending resize restyles: \(pending)"
    }

    /// Waits until the editor is styled at the current content width. Layout and display after
    /// a restyle can show or hide a legacy scroller, which changes the width and schedules a
    /// debounced restyle, so every check follows a drain that displays the window.
    func waitUntilStyledAtCurrentWidth(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        require("a restyle at the current width (\(contentWidthState))", timeout: timeout, file: file, line: line) {
            drainUntilIdle()
            return isStyledAtCurrentWidth
        }
    }

    /// Waits for background diagram renders to finish.
    func waitForDiagramRenders(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        require("the diagram renders to finish", timeout: timeout, file: file, line: line) {
            DiagramImageRenderer.shared.waitUntilIdle(timeout: 0.001)
        }
    }

    /// Waits until diagram renders, HTML block layout, and the restyle at the current width are
    /// all done. Each can start another (a measured HTML block changes the document height, which
    /// can show the scroller), so all must hold after the same drain.
    func settleBackgroundWork(timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        let diagramsIdle = { DiagramImageRenderer.shared.waitUntilIdle(timeout: 0.001) }
        let state = {
            "diagram renders idle: \(diagramsIdle()), HTML block layout pending: "
                + "\(self.textView.hasPendingHTMLBlockLayout), \(self.contentWidthState)"
        }
        require("the background work to finish (\(state()))", timeout: timeout, file: file, line: line) {
            drainUntilIdle()
            return diagramsIdle() && !textView.hasPendingHTMLBlockLayout && isStyledAtCurrentWidth
        }
    }

    /// Waits for initial layout, background diagram renders, and the first restyle to finish.
    func settle() {
        drainUntilIdle()
        waitForDiagramRenders()
        drainUntilQuiet(quietPeriod: 0.15)
        waitUntilStyledAtCurrentWidth()
    }
}
