import AppKit
import XCTest
@testable import Folio

/// The editor restyles when the content width changes, also when only the clip view changes: a
/// legacy scroller that appears or hides takes its width from the text.
@MainActor
final class ContentWidthRestyleTests: XCTestCase {
    private func openChapter() throws -> EditorHarness {
        LaTeXProjectContext.removeAll()
        addTeardownBlock { @MainActor in LaTeXProjectContext.removeAll() }
        let directory = try makeTemporaryDirectory("ContentWidth").appendingPathComponent("project")
        try FileManager.default.copyItem(at: LaTeXProjectFixtures.fixtureDirectory, to: directory)
        let fileURL = directory.appendingPathComponent("chapter.tex")
        // Paragraphs after the chapter make the document taller than the window.
        let filler = (1...40).map { "Filler paragraph \($0) after the entries." }.joined(separator: "\n\n")
        let text = try String(contentsOf: fileURL, encoding: .utf8) + "\n" + filler + "\n"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        let harness = try EditorHarness(
            workspace: PerfFixtures.Workspace(directory: directory, fileURL: fileURL, document: PerfFixtures.Document(markdown: text, paragraphLines: [])),
            size: NSSize(width: 900, height: 500)
        )
        harness.settleResizeRestyle()
        return harness
    }

    private func assertMatchesFullRestyle(_ harness: EditorHarness, _ message: String, line: UInt = #line) {
        harness.settleResizeRestyle()
        if let mismatch = RestyleEquivalenceOracle.firstMismatch(in: harness) {
            XCTFail("\(message): \(mismatch)", line: line)
        }
    }

    func testScrollerStyleChangeRestylesMultiLineCall() throws {
        let harness = try openChapter()
        defer { harness.tearDown() }
        let scrollView = try XCTUnwrap(harness.textView.enclosingScrollView)
        harness.moveCursor(toLine: 2)
        assertMatchesFullRestyle(harness, "after opening")
        XCTAssertTrue(scrollView.verticalScroller?.isHidden == false, "the document must be taller than the window")

        let legacyWidth = harness.coordinator.currentContentWidth(for: harness.textView)
        scrollView.scrollerStyle = .overlay
        harness.drainUntilIdle()
        XCTAssertGreaterThan(harness.coordinator.currentContentWidth(for: harness.textView), legacyWidth, "an overlay scroller takes no width")
        assertMatchesFullRestyle(harness, "after the scroller stopped taking width")
        harness.moveCursor(toLine: 2, column: 4)
        assertMatchesFullRestyle(harness, "after a cursor move on the same line")

        scrollView.scrollerStyle = .legacy
        harness.drainUntilIdle()
        assertMatchesFullRestyle(harness, "after the scroller took width again")
        harness.type("x")
        assertMatchesFullRestyle(harness, "after an edit before the call")
    }

    func testThemeAndTypographyChangesRestyleMultiLineCall() throws {
        let harness = try openChapter()
        defer { harness.tearDown() }
        harness.moveCursor(toLine: 2)
        harness.viewModel.theme = EditorTheme.builtInThemes.first { $0.isDark } ?? .daylight
        harness.drainUntilIdle()
        assertMatchesFullRestyle(harness, "after a theme change")
        var typography = harness.viewModel.typography
        typography.fontSizeScale = 1.2
        harness.viewModel.typography = typography
        harness.drainUntilIdle()
        assertMatchesFullRestyle(harness, "after a typography change")
        harness.type("x")
        assertMatchesFullRestyle(harness, "after an edit before the call")
    }
}
