import AppKit
import Foundation
import XCTest
@testable import Folio

@MainActor
final class SelectionCommentAndCopyTests: XCTestCase {

    private func makeViewModelWithoutAutosave() -> EditorWorkspaceViewModel {
        let vm = makeIsolatedViewModel()
        vm.autoSaveEnabled = false
        return vm
    }

    func testCopyRawWritesExactMarkdownToPasteboard() {
        let doc = "# Heading\n\nHere is **bold**, *italic*, and a [link](https://example.com).\n"
        let nsDoc = doc as NSString
        let targetRange = nsDoc.range(of: "**bold**, *italic*, and a [link](https://example.com)")

        let pasteboard = NSPasteboard.withUniqueName()
        MarkdownCopyFormatter.copyRaw(in: doc, range: targetRange, pasteboard: pasteboard)

        let copied = pasteboard.string(forType: .string)
        XCTAssertEqual(copied, "**bold**, *italic*, and a [link](https://example.com)")
        XCTAssertNil(pasteboard.data(forType: .rtf))
    }

    func testCopyFormattedStripsSyntaxAndWritesRichTextAndHTML() throws {
        let doc = """
            # Architecture Overview

            Here is **bold**, *italic*, `code`, and [Folio](https://example.com).
            - First bullet
            - Second bullet
            """
        let fullRange = NSRange(location: 0, length: (doc as NSString).length)
        let pasteboard = NSPasteboard.withUniqueName()

        MarkdownCopyFormatter.copyFormatted(
            in: doc,
            range: fullRange,
            theme: .daylight,
            typography: .default,
            pasteboard: pasteboard
        )

        let plain = pasteboard.string(forType: .string) ?? ""
        XCTAssertTrue(plain.contains("Architecture Overview"), "Plain text should preserve heading text: \(plain)")
        XCTAssertFalse(plain.contains("# "), "Plain text should strip ATX heading hashes: \(plain)")
        XCTAssertTrue(plain.contains("Here is bold, italic, code, and Folio."), "Plain text should strip inline delimiters: \(plain)")
        XCTAssertFalse(plain.contains("**bold**"), "Plain text should not contain ** markers")
        XCTAssertFalse(plain.contains("https://example.com"), "Plain text should strip link URL syntax")
        XCTAssertTrue(plain.contains("• First bullet"), "Unordered list markers should copy as bullets: \(plain)")

        let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf), "Copy Formatted must provide RTF data on pasteboard")
        let rich = try XCTUnwrap(NSAttributedString(rtf: rtfData, documentAttributes: nil))
        XCTAssertTrue(rich.string.contains("Here is bold, italic, code, and Folio."), "RTF text drops the syntax: \(rich.string)")
        let boldLocation = (rich.string as NSString).range(of: "bold").location
        let boldFont = try XCTUnwrap(rich.attribute(.font, at: boldLocation, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold), "RTF keeps **bold** as a bold font")

        let htmlString = pasteboard.string(forType: .html) ?? ""
        XCTAssertTrue(htmlString.contains("<h1>Architecture Overview</h1>"), "HTML should include semantic heading: \(htmlString)")
        XCTAssertTrue(htmlString.contains("<strong>bold</strong>"), "HTML should include strong tag: \(htmlString)")
        XCTAssertTrue(htmlString.contains("<a href=\"https://example.com\">Folio</a>"), "HTML should include anchor tag: \(htmlString)")
    }

    func testSelectionCommentLineNumbersAndAgentPasteFormat() {
        let doc = """
            # Folio Spec
            Line two intro
            func computeLayout() {
                return 42
            }
            Trailing line
            """
        let nsDoc = doc as NSString
        let targetRange = nsDoc.range(of: "func computeLayout() {\n    return 42\n}")

        let span = SelectionComment.lineSpan(for: targetRange, in: doc)
        XCTAssertEqual(span.lowerBound, 3)
        XCTAssertEqual(span.upperBound, 5)
        XCTAssertEqual(SelectionComment.lineRangeLabel(for: targetRange, in: doc), "L3–L5")

        let comment = SelectionComment(
            range: targetRange,
            selectedRawText: nsDoc.substring(with: targetRange),
            selectedFormattedText: nsDoc.substring(with: targetRange),
            commentText: "Extract this magic constant into a named configuration parameter."
        )

        let workspaceURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/docs/engine.md")
        let formatted = comment.formatForAgentPaste(
            documentTitle: "engine.md",
            fileURL: fileURL,
            workspaceFolderURL: workspaceURL,
            documentText: doc
        )

        let expected = """
            **`docs/engine.md` (L3–L5)**
            > func computeLayout() {
            >     return 42
            > }

            Extract this magic constant into a named configuration parameter.
            """
        XCTAssertEqual(formatted, expected)
    }

    func testCommentRangeReconciliationAcrossEditsAndDeletions() {
        let original = "First paragraph.\n\nSecond target paragraph here.\n\nThird paragraph."
        let nsOrig = original as NSString
        let targetRange = nsOrig.range(of: "Second target paragraph here.")

        let comment = SelectionComment(
            range: targetRange,
            selectedRawText: "Second target paragraph here.",
            selectedFormattedText: "Second target paragraph here.",
            commentText: "Clarify wording here."
        )

        // 1. Insert text before the comment -> range shifts forward, text stays intact
        let editedBefore = "Inserted header!\n" + original
        let shifted = comment.reconciled(from: original, to: editedBefore)
        XCTAssertNotNil(shifted)
        XCTAssertEqual(shifted?.selectedRawText, "Second target paragraph here.")
        XCTAssertEqual((editedBefore as NSString).substring(with: shifted!.range), "Second target paragraph here.")

        // 2. Delete the commented section entirely -> comment is dropped
        let deletedTarget = "First paragraph.\n\nThird paragraph."
        let dropped = comment.reconciled(from: original, to: deletedTarget)
        XCTAssertNil(dropped, "Comment should be removed when its underlying text is completely deleted")
    }

    func testViewModelCommentLifecycleBatchCopyAndTooltipAnchor() {
        let vm = makeViewModelWithoutAutosave()
        let doc = """
            # Design Doc

            First section with **important** details.

            Second section with `code` implementation.
            """
        vm.markdownText = doc
        let nsDoc = doc as NSString

        // Initially no selection -> no tooltip anchor
        vm.updateSelectionStats(selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(vm.selectionTooltipAnchor)

        // Select first section -> tooltip anchor appears
        let firstRange = nsDoc.range(of: "First section with **important** details.")
        vm.updateSelectionStats(selectedRange: firstRange)
        XCTAssertNotNil(vm.selectionTooltipAnchor)
        XCTAssertEqual(vm.selectionTooltipAnchor?.range, firstRange)

        // Start comment draft and save
        vm.beginCommentOnCurrentSelection()
        XCTAssertEqual(vm.activeCommentDraftRange, firstRange)
        vm.activeCommentDraftText = "Expand on the edge cases here."
        let firstSaved = vm.addOrUpdateSelectionComment()
        XCTAssertNotNil(firstSaved)
        XCTAssertNil(vm.activeCommentDraftRange)
        XCTAssertEqual(vm.selectionComments.count, 1)
        XCTAssertEqual(vm.selectionComments.first?.selectedFormattedText, "First section with important details.")

        // Add second comment on second section
        let secondRange = nsDoc.range(of: "Second section with `code` implementation.")
        vm.updateSelectionStats(selectedRange: secondRange)
        vm.beginCommentOnCurrentSelection()
        vm.activeCommentDraftText = "Add benchmark numbers for this path."
        vm.addOrUpdateSelectionComment()
        XCTAssertEqual(vm.selectionComments.count, 2)

        // Batch copy all comments
        let pasteboard = NSPasteboard.withUniqueName()
        let batch = vm.copyAllSelectionComments(to: pasteboard)
        XCTAssertNotNil(batch)
        XCTAssertEqual(pasteboard.string(forType: .string), batch)
        XCTAssertTrue(batch!.contains("L3"))
        XCTAssertTrue(batch!.contains("Expand on the edge cases here."))
        XCTAssertTrue(batch!.contains("\n\n---\n\n"))
        XCTAssertTrue(batch!.contains("L5"))
        XCTAssertTrue(batch!.contains("Add benchmark numbers for this path."))

        // Context menu on HybridMarkdownTextView includes Comment, Copy Formatted, and Copy Raw
        let tv = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.workspaceViewModel = vm
        tv.string = doc
        tv.setSelectedRange(firstRange)
        let menu = tv.menu(for: NSEvent())
        let titles = menu?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Add Comment on Selection…"))
        XCTAssertTrue(titles.contains("Copy Formatted"))
        XCTAssertTrue(titles.contains("Copy Raw Markdown"))
    }

    func testCompanionCommentsFileAutosaveReloadAndCleanup() throws {
        let tempDir = try makeTemporaryDirectory("FolioCompanionCommentsTest")

        let docURL = tempDir.appendingPathComponent("Architecture.md")
        let expectedCompanionURL = tempDir.appendingPathComponent("Architecture.comments.folio.md")
        let docText = """
            # Architecture Overview

            The **TextKit** layout pipeline runs at 120Hz.

            ```swift
            func renderLiveMarkdown() -> Bool { true }
            ```
            """
        try docText.write(to: docURL, atomically: true, encoding: .utf8)

        let vm = makeViewModelWithoutAutosave()
        vm.autoSaveEnabled = true
        vm.autoSaveDelay = 0
        vm.workspaceFolderURL = tempDir
        vm.openFile(at: docURL)

        XCTAssertEqual(vm.currentCompanionCommentsURL?.standardizedFileURL, expectedCompanionURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedCompanionURL.path))

        let nsDoc = docText as NSString
        let firstRange = nsDoc.range(of: "The **TextKit** layout pipeline runs at 120Hz.")
        let secondRange = nsDoc.range(of: "func renderLiveMarkdown() -> Bool { true }")

        vm.addOrUpdateSelectionComment("Verify frame pacing on external displays.", for: firstRange)
        vm.addOrUpdateSelectionComment("Expose this in the public benchmark harness.", for: secondRange)

        // Companion .comments.folio.md file should be autosaved immediately next to Architecture.md
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedCompanionURL.path))
        let diskCompanion = try String(contentsOf: expectedCompanionURL, encoding: .utf8)
        XCTAssertTrue(diskCompanion.contains("**`Architecture.md` (L3)**"))
        XCTAssertTrue(diskCompanion.contains("> The **TextKit** layout pipeline runs at 120Hz."))
        XCTAssertTrue(diskCompanion.contains("Verify frame pacing on external displays."))
        XCTAssertTrue(diskCompanion.contains("Expose this in the public benchmark harness."))

        // Re-opening the document in a fresh ViewModel should restore all comments from <filename>.comments.folio.md
        let vmReloaded = makeViewModelWithoutAutosave()
        vmReloaded.autoSaveEnabled = true
        vmReloaded.autoSaveDelay = 0
        vmReloaded.workspaceFolderURL = tempDir
        vmReloaded.openFile(at: docURL)

        XCTAssertEqual(vmReloaded.selectionComments.count, 2)
        XCTAssertEqual(vmReloaded.selectionComments[0].range, firstRange)
        XCTAssertEqual(vmReloaded.selectionComments[0].commentText, "Verify frame pacing on external displays.")
        XCTAssertEqual(vmReloaded.selectionComments[1].range, secondRange)
        XCTAssertEqual(vmReloaded.selectionComments[1].commentText, "Expose this in the public benchmark harness.")

        // Companion .comments.folio.md files should be excluded from the workspace Markdown file list
        vmReloaded.reloadWorkspaceTree()
        let workspaceFileNames = vmReloaded.flatMarkdownFiles.map(\.name)
        XCTAssertTrue(workspaceFileNames.contains("Architecture.md"))
        XCTAssertFalse(workspaceFileNames.contains("Architecture.comments.folio.md"))

        // Clearing comments removes the companion file so no stale empty file lingers
        vmReloaded.clearAllSelectionComments()
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedCompanionURL.path))
    }

    func testSelectionDirectionDetectionAndVerticalTooltipAlignment() {
        let vm = makeViewModelWithoutAutosave()
        let doc = "First line of prose.\nSecond line of prose.\nThird line of prose."
        vm.markdownText = doc

        // 1. Forward selection (left-to-right / top-to-bottom)
        vm.updateSelectionStats(selectedRange: NSRange(location: 5, length: 0))
        vm.updateSelectionStats(selectedRange: NSRange(location: 5, length: 12))
        XCTAssertEqual(vm.currentSelectionDirection, .forward)
        XCTAssertEqual(vm.selectionTooltipAnchor?.direction, .forward)

        // 2. Backward selection (right-to-left / bottom-to-top, start moves earlier while end stays anchored)
        vm.updateSelectionStats(selectedRange: NSRange(location: 30, length: 0))
        vm.updateSelectionStats(selectedRange: NSRange(location: 14, length: 16))
        XCTAssertEqual(vm.currentSelectionDirection, .backward)
        XCTAssertEqual(vm.selectionTooltipAnchor?.direction, .backward)

        // 3. Verify intelligent positioning places backward selection tooltip on the top-left side
        // and forward selection tooltip on the bottom-right side of the selection
        let selRect = CGRect(x: 200, y: 180, width: 220, height: 44)
        let forwardAnchor = SelectionTooltipAnchor(
            range: NSRange(location: 5, length: 12),
            selectionRectInViewport: selRect,
            headRectInViewport: CGRect(x: 408, y: 202, width: 12, height: 22),
            direction: .forward,
            viewportSize: CGSize(width: 800, height: 600)
        )
        let backwardAnchor = SelectionTooltipAnchor(
            range: NSRange(location: 14, length: 16),
            selectionRectInViewport: selRect,
            headRectInViewport: CGRect(x: 200, y: 180, width: 12, height: 22),
            direction: .backward,
            viewportSize: CGSize(width: 800, height: 600)
        )

        let forwardPos = SelectionActionTooltipView.tooltipPosition(for: forwardAnchor, isExpanded: false)
        let backwardPos = SelectionActionTooltipView.tooltipPosition(for: backwardAnchor, isExpanded: false)
        XCTAssertGreaterThan(forwardPos.centerX, selRect.maxX, "Forward selection should align vertical icon rail to the trailing/right side")
        XCTAssertLessThan(backwardPos.centerX, selRect.minX, "Backward selection should align vertical icon rail to the leading/left side")
    }

    func testRightSidebarAndClickableHighlightedCommentRanges() {
        let vm = makeViewModelWithoutAutosave()
        let doc = "First paragraph here.\n\nCommented target phrase in middle.\n\nFinal paragraph below."
        vm.markdownText = doc
        let nsDoc = doc as NSString

        let tv = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        tv.workspaceViewModel = vm
        vm.activeTextView = tv
        tv.string = doc

        XCTAssertFalse(vm.isCommentsSidebarVisible)

        let firstRange = nsDoc.range(of: "First paragraph here.")
        let secondRange = nsDoc.range(of: "Commented target phrase in middle.")
        let c1 = vm.addOrUpdateSelectionComment("Check intro tone.", for: firstRange)!
        let c2 = vm.addOrUpdateSelectionComment("Verify this invariant.", for: secondRange)!

        XCTAssertTrue(vm.isCommentsSidebarVisible)
        XCTAssertEqual(vm.activeCommentID, c2.id)

        // Hide right sidebar, then click the first highlighted comment range in the editor
        vm.showCommentsSidebar = false
        XCTAssertFalse(vm.isCommentsSidebarVisible)

        let firstRects = tv.commentPieceRects(
            for: firstRange,
            nsLength: nsDoc.length,
            layoutManager: tv.layoutManager!,
            textContainer: tv.textContainer!,
            origin: tv.textContainerOrigin
        )
        XCTAssertFalse(firstRects.isEmpty)
        let clickPoint = NSPoint(x: firstRects[0].midX, y: firstRects[0].midY)

        let clicked = tv.handleClickOnCommentHighlight(at: clickPoint)
        XCTAssertEqual(clicked?.id, c1.id)
        XCTAssertEqual(vm.activeCommentID, c1.id, "Clicking highlighted comment should link to that comment")
        XCTAssertTrue(vm.isCommentsSidebarVisible, "Clicking highlighted comment should reveal the right sidebar")
    }
}
