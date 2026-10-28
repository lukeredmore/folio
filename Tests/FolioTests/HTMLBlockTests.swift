import AppKit
import WebKit
import XCTest
@testable import Folio

/// HTML blocks: classification, source-offset annotation, styling, and the web view bridge.
@MainActor
final class HTMLBlockTests: XCTestCase {

    static let barBlock = """
        <div style="display:flex;height:28px;">
        <div title="Home: 193.9 GB" style="flex:193.9;background:#2a78d6;"></div>
        <div title="Free: 51.1 GB" style="flex:51.1;border:1px dashed #b5b4ad;"></div>
        </div>
        """

    override func tearDown() {
        HTMLBlockLayoutCache.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Classification

    func testSelfContainedBlocksRenderInWebView() {
        for source in [
            Self.barBlock,
            "<table>\n<tr><td>a</td></tr>\n</table>",
            "<p style=\"color:red\">\nA paragraph without its end tag",
            "<pre>\n a < b\n</pre>"
        ] {
            XCTAssertTrue(HTMLBlockMarkup.rendersInWebView(source), source)
        }
    }

    func testNativeAndWrapperBlocksKeepNativeStyling() {
        for source in [
            "<div align=\"center\">",
            "</div>",
            "<img src=\"a.png\" />",
            "<video src=\"a.mp4\"></video>",
            "<details>\n<summary>More</summary>",
            "<svg viewBox=\"0 0 1 1\"></svg>",
            "<!-- note -->",
            "<script>alert(1)</script>",
            "<div>\n<span>an unclosed div"
        ] {
            XCTAssertFalse(HTMLBlockMarkup.rendersInWebView(source), source)
        }
    }

    // MARK: - Annotation

    func testAnnotationWrapsTextRunsWithSourceOffsets() {
        let source = "<p title=\"a > b\">Hi &amp; bye</p>"
        let ns = source as NSString
        let start = ns.range(of: "Hi").location
        let end = ns.range(of: "</p>").location
        XCTAssertEqual(
            HTMLBlockMarkup.annotatedMarkup(source),
            "<p title=\"a > b\"><span data-fs=\"\(start)\" data-fe=\"\(end)\">Hi &amp; bye</span></p>"
        )
    }

    func testAnnotationSkipsWhitespaceRawTextAndForeignContent() {
        let source = "<div>\n<svg><text>t</text></svg>\n<select><option>o</option></select>\n<style>p { color: red }</style>\n</div>"
        XCTAssertEqual(HTMLBlockMarkup.annotatedMarkup(source), source)
    }

    func testAnnotationKeepsTheNewlineThatPreDrops() {
        XCTAssertEqual(
            HTMLBlockMarkup.annotatedMarkup("<pre>\ncode\n</pre>"),
            "<pre>\n<span data-fs=\"6\" data-fe=\"11\">code\n</span></pre>"
        )
    }

    // MARK: - Styling

    private func style(_ markdown: String, selection: NSRange, prettyMode: Bool = true) -> (NSTextStorage, MarkdownDocumentAnalysis) {
        let storage = NSTextStorage(string: markdown)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage, theme: .daylight, sourceCodeMode: false, focusMode: false,
            selectedRange: selection, containerWidth: 640, prettyMode: prettyMode
        )
        return (storage, analysis)
    }

    private func renderedBlocks(_ analysis: MarkdownDocumentAnalysis) -> [(source: String, range: NSRange)] {
        analysis.decorations.compactMap { decoration in
            guard case let .htmlBlockRendered(source, range, _, _) = decoration.kind else { return nil }
            return (source, range)
        }
    }

    func testInactiveBlockIsHiddenAndDecorated() throws {
        let markdown = "Intro paragraph.\n\n\(Self.barBlock)\n\nAfter."
        let (storage, analysis) = style(markdown, selection: NSRange(location: 0, length: 0))
        let blockStart = (markdown as NSString).range(of: "<div").location

        let block = try XCTUnwrap(renderedBlocks(analysis).first)
        XCTAssertEqual(renderedBlocks(analysis).count, 1)
        XCTAssertEqual(block.source, Self.barBlock)
        XCTAssertEqual(block.range, NSRange(location: blockStart, length: (Self.barBlock as NSString).length + 1))
        let color = try XCTUnwrap(storage.attribute(.foregroundColor, at: blockStart + 2, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color.alphaComponent, 0)
    }

    func testCaretInBlockShowsHighlightedSource() {
        let markdown = "Intro paragraph.\n\n\(Self.barBlock)\n\nAfter."
        let blockStart = (markdown as NSString).range(of: "<div").location
        let (_, analysis) = style(markdown, selection: NSRange(location: blockStart + 3, length: 0))
        XCTAssertTrue(renderedBlocks(analysis).isEmpty)
        XCTAssertTrue(analysis.decorations.contains { $0.kind == .codeFenceBody && $0.lineRange.location == blockStart })
    }

    func testPreBlockRunsToItsClosingTag() throws {
        let pre = "<pre>\n$ du -sh ~/workplace\n 43G    /Users/me/workplace\n</pre>"
        let markdown = "## Preformatted\n\n\(pre)\n\n## Next\n"
        let (_, analysis) = style(markdown, selection: NSRange(location: 0, length: 0))
        let block = try XCTUnwrap(renderedBlocks(analysis).first)
        XCTAssertEqual(block.source, pre)
        XCTAssertEqual(MarkdownLiveStyler.rawTextBlockClosingTag(firstLine: "<pre class=\"x\">"), "</pre")
        XCTAssertNil(MarkdownLiveStyler.rawTextBlockClosingTag(firstLine: "<prefix>"))
    }

    func testBlocksKeepNativeStylingOutsidePrettyMode() {
        let markdown = "Intro.\n\n\(Self.barBlock)\n"
        let (_, analysis) = style(markdown, selection: NSRange(location: 0, length: 0), prettyMode: false)
        XCTAssertTrue(renderedBlocks(analysis).isEmpty)
    }

    func testHiddenLinesReserveTheMeasuredHeight() throws {
        let style = HTMLBlockPageStyle(theme: .daylight, typography: EditorTheme.daylight.typography)
        let key = HTMLBlockLayoutCache.key(source: Self.barBlock, width: 640, style: style)
        HTMLBlockLayoutCache.shared.setHeight(121, for: key)

        let markdown = "Intro.\n\n\(Self.barBlock)\n\nAfter."
        let (storage, analysis) = self.style(markdown, selection: NSRange(location: 0, length: 0))
        let range = try XCTUnwrap(renderedBlocks(analysis).first?.range)
        let lineCount = Self.barBlock.components(separatedBy: "\n").count
        let perLine = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight
        XCTAssertEqual(perLine, floor(121 / CGFloat(lineCount)))
        XCTAssertEqual(MarkdownLiveStyler.hiddenLineHeights(totalHeight: 121, lineCount: lineCount).reduce(0, +), 121)
    }

    func testHiddenLineHeightsAddUpWithAMinimumPerLine() {
        XCTAssertEqual(MarkdownLiveStyler.hiddenLineHeights(totalHeight: 100, lineCount: 3), [33, 33, 34])
        XCTAssertEqual(MarkdownLiveStyler.hiddenLineHeights(totalHeight: 3, lineCount: 4), [2, 2, 2, 2])
    }

    // MARK: - Assets and Messages

    func testAssetURLsStayInsideTheDocumentFolder() {
        let base = URL(fileURLWithPath: "/tmp/folio-doc", isDirectory: true)
        let resolve = { (string: String) in HTMLBlockAssetSchemeHandler.fileURL(for: URL(string: string), baseDirectoryURL: base)?.path }
        XCTAssertEqual(resolve("folio-doc://local/assets/a.png"), "/tmp/folio-doc/assets/a.png")
        XCTAssertNil(resolve("folio-doc://local/../secret.txt"))
        XCTAssertNil(resolve("folio-doc://local/assets/%2E%2E/%2E%2E/etc/passwd"))
        XCTAssertNil(resolve("https://example.com/a.png"))
        XCTAssertNil(HTMLBlockAssetSchemeHandler.fileURL(for: URL(string: "folio-doc://local/a.png"), baseDirectoryURL: nil))
    }

    func testSelectionMessagesAreClampedToTheSource() {
        let message: [String: Any] = [
            "type": "selection", "empty": false, "start": 4, "end": 99, "backward": true,
            "rects": [[1, 2, 30, 18], [5, 6]]
        ]
        XCTAssertEqual(
            HTMLBlockWebView.selection(from: message, sourceLength: 20),
            HTMLBlockWebView.Selection(start: 4, end: 20, rects: [NSRect(x: 1, y: 2, width: 30, height: 18)], isBackward: true)
        )
        XCTAssertNil(HTMLBlockWebView.selection(from: ["type": "selection", "empty": true], sourceLength: 20))
        XCTAssertNil(HTMLBlockWebView.selection(from: ["empty": false, "start": 5, "end": 5], sourceLength: 20))
    }

    // MARK: - Web View Bridge

    private final class RecordingDelegate: HTMLBlockWebViewDelegate {
        var selections: [HTMLBlockWebView.Selection?] = []
        var heights: [CGFloat] = []

        func htmlBlockWebView(_ view: HTMLBlockWebView, didMeasureHeight height: CGFloat) { heights.append(height) }
        func htmlBlockWebView(_ view: HTMLBlockWebView, didChangeSelection selection: HTMLBlockWebView.Selection?) {
            selections.append(selection)
        }
        func htmlBlockWebView(_ view: HTMLBlockWebView, didClickSourceOffset offset: Int?, clickCount: Int) {}
        func htmlBlockWebViewDidBecomeReady(_ view: HTMLBlockWebView) {}
        func htmlBlockWebViewRequestsSourceEditing(_ view: HTMLBlockWebView) {}
        func htmlBlockWebViewRequestsComment(_ view: HTMLBlockWebView) {}
        func htmlBlockWebViewRequestsRawCopy(_ view: HTMLBlockWebView) {}
        func htmlBlockWebViewRequestsTextFocus(_ view: HTMLBlockWebView) {}
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    /// Mean of (blue - red) over `rect` (page points) in a snapshot of `view`.
    private func snapshotBlueShift(_ view: HTMLBlockWebView, in rect: NSRect) -> CGFloat? {
        var image: NSImage?
        var done = false
        Task { @MainActor in
            image = await view.captureSnapshot()
            done = true
        }
        guard waitUntil(timeout: 5, { done }), let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += color.blueComponent - color.redComponent
                count += 1
            }
        }
        return count > 0 ? total / count : nil
    }

    func testWebViewRoundTripsSourceRangesThroughEntities() throws {
        let source = "<p>Disk &amp; volume <b>usage</b></p>"
        let ns = source as NSString
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let delegate = RecordingDelegate()
        let view = HTMLBlockWebView(
            source: source, style: HTMLBlockPageStyle(theme: .daylight, typography: EditorTheme.daylight.typography),
            baseDirectoryURL: nil, blockRange: NSRange(location: 0, length: ns.length), layoutWidth: 400
        )
        view.blockDelegate = delegate
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        window.contentView?.addSubview(view)

        XCTAssertTrue(waitUntil(timeout: 20) { view.isReady }, "The page did not load")
        XCTAssertGreaterThan(try XCTUnwrap(view.measuredHeight), 10)

        let word = ns.range(of: "volume")
        view.selectSource(start: word.location, end: NSMaxRange(word))
        XCTAssertTrue(waitUntil(timeout: 5) { view.selection != nil }, "The page did not report the selection")
        let selection = try XCTUnwrap(view.selection)
        XCTAssertEqual(selection.start, word.location)
        XCTAssertEqual(selection.end, NSMaxRange(word))
        XCTAssertFalse(selection.rects.isEmpty)

        let across = NSRange(location: ns.range(of: "Disk").location, length: ns.range(of: "</b>").location - ns.range(of: "Disk").location)
        view.selectSource(start: across.location, end: NSMaxRange(across))
        XCTAssertTrue(waitUntil(timeout: 5) { view.selection?.start == across.location })
        XCTAssertEqual(view.selection?.end, NSMaxRange(across))

        let wordRect = try XCTUnwrap(selection.rects.first)
        view.clearSelection()
        let plain = try XCTUnwrap(snapshotBlueShift(view, in: wordRect))
        view.setHighlights([HTMLBlockWebView.Highlight(start: word.location, end: NSMaxRange(word), kind: "folio-comment-active")])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let painted = try XCTUnwrap(snapshotBlueShift(view, in: wordRect))
        print("DEBUG blue shift plain", plain, "painted", painted)
        XCTAssertGreaterThan(painted - plain, 0.02, "The page must paint the comment highlight")
        view.setHighlights([])
        view.selectSource(start: across.location, end: NSMaxRange(across))
        XCTAssertTrue(waitUntil(timeout: 5) { view.selection?.start == across.location })

        XCTAssertEqual(delegate.selections.last ?? nil, view.selection)
        view.clearSelection()
        XCTAssertNil(view.selection)
        view.selectSource(start: word.location, end: NSMaxRange(word))
        XCTAssertTrue(waitUntil(timeout: 5) { view.selection?.start == word.location }, "Selecting again after a clear must report")
    }

    // MARK: - Editor Integration

    private func paintedCounts(_ view: HTMLBlockWebView, _ harness: EditorHarness) -> [String: Int] {
        var counts: [String: Int]?
        Task { @MainActor in counts = await view.paintedHighlightCounts() }
        harness.waitUntil(timeout: 5) { counts != nil }
        return counts ?? [:]
    }

    /// The tooltip path: select in the page, press Comment, type, press Save. The saved comment
    /// must stay painted in the page after the editor settles (sidebar, resize restyle, focus).
    func testSavedCommentStaysHighlightedInThePage() throws {
        // Narrow, so opening the comments sidebar narrows the editor column and restyles it.
        let harness = try EditorHarness(
            workspace: PerfFixtures.makeWorkspace(copyingExample: "html_blocks_showcase.md"),
            size: NSSize(width: 900, height: 800)
        )
        defer { harness.tearDown() }
        let textView = harness.textView
        let viewModel = harness.viewModel
        let text = textView.string as NSString
        let tableStart = text.range(of: "<table>").location
        let cell = text.range(of: "Dev volumes</td>")
        let target = NSRange(location: cell.location, length: ("Dev volumes" as NSString).length)

        textView.scrollRangeToVisible(NSRange(location: tableStart, length: 1))
        textView.syncHTMLBlockOverlays()
        XCTAssertTrue(harness.waitUntil(timeout: 20) { textView.htmlBlockOverlays.contains { $0.blockRange.location == tableStart && $0.isReady } })
        XCTAssertTrue(textView.selectHTMLBlockSource(target))
        XCTAssertTrue(harness.waitUntil(timeout: 5) { viewModel.selectionTooltipAnchor?.range == target })
        let anchor = try XCTUnwrap(viewModel.selectionTooltipAnchor)

        viewModel.beginCommentOnCurrentSelection(for: anchor.range)
        harness.drainUntilIdle()
        // The tooltip's comment field takes focus from the web view, as a click on it does.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        harness.window.contentView?.addSubview(field)
        defer { field.removeFromSuperview() }
        harness.window.makeFirstResponder(field)
        harness.drainUntilQuiet(quietPeriod: 0.3)
        XCTAssertEqual(viewModel.activeCommentDraftRange, target, "Moving focus to the comment field must keep the draft")
        XCTAssertEqual(textView.htmlBlockSelection?.sourceRange, target, "Losing focus must keep the page selection")
        XCTAssertNotNil(viewModel.selectionTooltipAnchor, "The comment tooltip must stay open")
        viewModel.activeCommentDraftText = "Second largest"
        let widthBefore = textView.bounds.width
        // The Save button and Return save the draft range, as the tooltip does after focus moved.
        let saved = try XCTUnwrap(viewModel.addOrUpdateSelectionComment(for: viewModel.selectionTooltipAnchor?.range))
        XCTAssertEqual(saved.range, target)
        harness.drainUntilQuiet(quietPeriod: 1.0)
        XCTAssertTrue(harness.waitUntil(timeout: 20) { !textView.hasPendingHTMLBlockLayout })

        XCTAssertLessThan(textView.bounds.width, widthBefore, "The comments sidebar must narrow the editor")
        XCTAssertEqual(viewModel.selectionComments.map(\.range), [target], "The comment must survive the save")
        XCTAssertTrue(textView.renderedHTMLBlocks().contains { $0.range.location == tableStart }, "The block must stay rendered")
        let view = try XCTUnwrap(textView.htmlBlockOverlays.first { $0.blockRange.location == tableStart })
        let counts = paintedCounts(view, harness)
        XCTAssertEqual((counts["folio-comment"] ?? 0) + (counts["folio-comment-active"] ?? 0), 1, "The page must paint the saved comment: \(counts)")
        XCTAssertEqual(counts["folio-draft"], 0)
    }

    func testEditorOverlaysBlocksAndCommentsOnWebSelections() throws {
        let harness = try EditorHarness(workspace: PerfFixtures.makeWorkspace(copyingExample: "html_blocks_showcase.md"))
        defer { harness.tearDown() }
        let textView = harness.textView
        XCTAssertTrue(
            harness.waitUntil(timeout: 20) { !textView.htmlBlockOverlays.isEmpty && !textView.hasPendingHTMLBlockLayout },
            "No HTML block web view became ready"
        )
        harness.drainUntilIdle()

        let text = textView.string as NSString
        let tableStart = text.range(of: "<table>").location
        let table = try XCTUnwrap(textView.renderedHTMLBlocks().first { $0.range.location == tableStart })
        XCTAssertNil(textView.renderedHTMLBlocks().first { text.substring(with: $0.range).hasPrefix("<img") })

        textView.scrollRangeToVisible(table.range)
        textView.syncHTMLBlockOverlays()
        XCTAssertTrue(harness.waitUntil(timeout: 20) { textView.htmlBlockOverlays.contains { $0.blockRange == table.range && $0.isReady } })
        let overlay = try XCTUnwrap(textView.htmlBlockOverlays.first { $0.blockRange == table.range })
        let reserved = try XCTUnwrap(textView.htmlBlockReservedRect(for: table.range))
        XCTAssertEqual(overlay.frame.minY, reserved.minY, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.height, try XCTUnwrap(overlay.measuredHeight), accuracy: 1.0)

        let cell = text.range(of: "193.9 GB</td>")
        let target = NSRange(location: cell.location, length: ("193.9 GB" as NSString).length)
        XCTAssertTrue(textView.selectHTMLBlockSource(target))
        XCTAssertTrue(harness.waitUntil(timeout: 5) { textView.htmlBlockSelection?.sourceRange == target })
        XCTAssertEqual(harness.viewModel.effectiveCommentTargetRange(), target)
        XCTAssertNotNil(harness.viewModel.selectionTooltipAnchor)

        let comment = try XCTUnwrap(harness.viewModel.addOrUpdateSelectionComment("Largest volume"))
        XCTAssertEqual(comment.range, target)
        XCTAssertEqual(comment.selectedRawText, "193.9 GB")

        harness.moveCursor(toLine: harness.lineCount - 1)
        XCTAssertNil(textView.htmlBlockSelection, "A text selection must replace the block selection")

        textView.scrollRangeToVisible(table.range)
        textView.syncHTMLBlockOverlays()
        XCTAssertTrue(harness.waitUntil(timeout: 20) { textView.htmlBlockOverlays.contains { $0.blockRange == table.range && $0.isReady } })
        let clicked = try XCTUnwrap(textView.htmlBlockOverlays.first { $0.blockRange == table.range })
        let isRendered = { textView.renderedHTMLBlocks().contains { $0.range.location == tableStart } }
        let settle = { harness.waitUntil(timeout: NSEvent.doubleClickInterval + 0.5) { textView.pendingHTMLBlockSourceToggle == nil } }

        textView.htmlBlockWebView(clicked, didClickSourceOffset: target.location - tableStart + 2, clickCount: 1)
        XCTAssertEqual(harness.viewModel.activeCommentID, comment.id, "A click on a comment highlight must open the comment")
        XCTAssertTrue(settle())
        XCTAssertTrue(isRendered(), "A click on a comment highlight must not show the source")

        let dev = text.range(of: "Dev volumes</td>").location - tableStart
        textView.htmlBlockWebView(clicked, didClickSourceOffset: dev, clickCount: 1)
        textView.htmlBlockWebView(clicked, didClickSourceOffset: dev, clickCount: 2)
        XCTAssertTrue(settle())
        XCTAssertTrue(isRendered(), "A double click selects text and must not show the source")

        textView.htmlBlockWebView(clicked, didClickSourceOffset: dev, clickCount: 1)
        XCTAssertTrue(harness.waitUntil(timeout: NSEvent.doubleClickInterval + 2) { !isRendered() }, "A click must show the block source")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: tableStart + dev, length: 0))
        XCTAssertTrue(harness.waitUntil(timeout: 2) { !textView.htmlBlockOverlays.contains { $0.blockRange.location == tableStart } })
    }
}
