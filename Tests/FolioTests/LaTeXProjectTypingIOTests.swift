import AppKit
import XCTest
@testable import Folio

/// The live editor resolves a LaTeX child's master once, on open, and typing does no file I/O.
@MainActor
final class LaTeXProjectTypingIOTests: XCTestCase {
    func testTypingInChildFileDoesNoFileIO() throws {
        LaTeXProjectContext.removeAll()
        let directory = try makeTemporaryDirectory("LaTeXTypingIO").appendingPathComponent("project")
        try FileManager.default.copyItem(at: LaTeXProjectFixtures.fixtureDirectory, to: directory)
        let child = directory.appendingPathComponent("chapter.tex")
        let text = try String(contentsOf: child, encoding: .utf8)
        let operationsBeforeOpen = LaTeXProjectFileSystem.liveOperationCount
        let harness = try EditorHarness(
            workspace: PerfFixtures.Workspace(
                directory: directory, fileURL: child, document: PerfFixtures.Document(markdown: text, paragraphLines: [])
            )
        )
        defer {
            harness.tearDown()
            LaTeXProjectContext.removeAll()
        }
        harness.drainUntilQuiet(quietPeriod: 0.25)
        XCTAssertGreaterThan(LaTeXProjectFileSystem.liveOperationCount, operationsBeforeOpen, "opening the child resolves its master")
        XCTAssertTrue(
            harness.textView.lineDecorations.contains {
                if case .latexInlineRichText = $0.kind { return true }
                return false
            }, "macros inherited from the master expand after open")

        let proseLine = 9
        XCTAssertTrue(harness.lineText(proseLine).hasPrefix("The \\Product"), "fixture layout changed")
        harness.moveCursor(toLine: proseLine, column: .max)
        let before = harness.counters
        let typed = " and more words"
        harness.type(typed)
        let delta = harness.counters.delta(since: before)
        PerfReport.record("latexChildTyping_\(typed.count)keys", PerfReport.values(delta, keys: typed.count))

        XCTAssertTrue(harness.lineText(proseLine).hasSuffix(typed), "key events did not insert text")
        XCTAssertGreaterThanOrEqual(delta.restyleCount, typed.count, "each key must restyle")
        XCTAssertEqual(delta.latexFileOperationCount, 0, "typing must not stat, read, or list LaTeX project files")
    }
}
