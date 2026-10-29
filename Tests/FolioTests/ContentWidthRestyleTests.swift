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
        harness.waitUntilStyledAtCurrentWidth()
        return harness
    }

    private func assertMatchesFullRestyle(_ harness: EditorHarness, _ message: String, line: UInt = #line) {
        harness.waitUntilStyledAtCurrentWidth()
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

    /// A document that fits the window until `late.png` loads, with that file still missing.
    private func openLateImageDocument(size: NSSize) throws -> EditorHarness {
        let directory = try makeTemporaryDirectory("LateImage")
        let fileURL = directory.appendingPathComponent("late-image.md")
        let paragraphs = (1...6).map { "Paragraph \($0) before the image." }.joined(separator: "\n\n")
        let text = "# Late image\n\n\(paragraphs)\n\n![late](late.png)\n"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return try EditorHarness(
            workspace: PerfFixtures.Workspace(directory: directory, fileURL: fileURL, document: PerfFixtures.Document(markdown: text, paragraphLines: [])),
            size: size
        )
    }

    /// Writes a 400 pt square `late.png` and posts the notification of a finished image load.
    private func loadLateImage(_ harness: EditorHarness) throws {
        let image = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )?.representation(using: .png, properties: [:]))
        try image.write(to: harness.workspace.directory.appendingPathComponent("late.png"))
        NotificationCenter.default.post(name: FolioMediaImageCache.imageDidLoadNotification, object: nil)
    }

    /// An image that loads after the first restyle makes the document taller than the window,
    /// and the legacy scroller that then appears narrows the text.
    func testImageThatShowsTheScrollerRestylesAtTheNarrowerWidth() throws {
        let harness = try openLateImageDocument(size: NSSize(width: 900, height: 800))
        defer { harness.tearDown() }
        let scrollView = try XCTUnwrap(harness.textView.enclosingScrollView)
        XCTAssertTrue(scrollView.verticalScroller?.isHidden ?? true, "the document must fit the window before the image loads")
        let widthBefore = harness.coordinator.currentContentWidth(for: harness.textView)

        try loadLateImage(harness)
        harness.waitUntilStyledAtCurrentWidth()

        XCTAssertFalse(scrollView.verticalScroller?.isHidden ?? true, "the image must make the document taller than the window")
        XCTAssertLessThan(harness.coordinator.currentContentWidth(for: harness.textView), widthBefore - 1, "the scroller must take width")
        assertMatchesFullRestyle(harness, "after the image loaded")
    }

    /// The scroller hides when the window grows, and before the debounced resize restyle runs,
    /// an image load restyles at the wider width. That restyle makes the document taller, so
    /// the scroller appears again during it, back at the width of the last restyle.
    func testScrollerThatReturnsDuringARestyleRestylesAgain() throws {
        let harness = try openLateImageDocument(size: NSSize(width: 900, height: 300))
        defer { harness.tearDown() }
        let scrollView = try XCTUnwrap(harness.textView.enclosingScrollView)
        XCTAssertFalse(scrollView.verticalScroller?.isHidden ?? true, "the document must be taller than the short window")
        let narrowWidth = harness.coordinator.lastContentWidth
        let manual = ManualEditorScheduler()
        harness.coordinator.scheduler = manual.scheduler

        var frame = harness.window.frame
        frame.size.height = 800
        harness.window.setFrame(frame, display: true)
        harness.require("the scroller to hide", timeout: 2) {
            harness.coordinator.currentContentWidth(for: harness.textView) > narrowWidth + 1
        }
        XCTAssertEqual(manual.liveCount, 1, "the wider width must schedule a restyle")

        try loadLateImage(harness)
        XCTAssertEqual(harness.coordinator.currentContentWidth(for: harness.textView), narrowWidth, accuracy: 0.5, "the scroller must return")
        harness.coordinator.scheduler = .live
        manual.flush()
        harness.waitUntilStyledAtCurrentWidth(timeout: 2)
        assertMatchesFullRestyle(harness, "after the scroller returned during the image restyle")
    }
}
