import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class AutosaveAndUndoHistoryTests: XCTestCase {

    @MainActor
    func testAutomaticAutosaveAndInfiniteUndoRedoAcrossEditsAndRelaunches() throws {
        let suiteName = "com.folio.tests.infiniteundo.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioInfiniteUndoTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileA = tempDir.appendingPathComponent("NoteA.md")
        let fileB = tempDir.appendingPathComponent("NoteB.md")
        try "Line 0".write(to: fileA, atomically: true, encoding: .utf8)
        try "Initial B".write(to: fileB, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.openFolder(at: tempDir)
        vm.openFile(at: fileA)
        XCTAssertEqual(vm.markdownText, "Line 0")
        XCTAssertFalse(vm.canUndo)

        // Perform 25 distinct edits (breaking undo coalescing between each) and verify each auto-saves immediately
        for step in 1...25 {
            vm.breakUndoCoalescing()
            let updated = (0...step).map { "Line \($0)" }.joined(separator: "\n")
            vm.handleEditorTextEdited(updated, selectedRange: NSRange(location: (updated as NSString).length, length: 0))
            XCTAssertFalse(vm.isDirty)
            XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), updated)
        }

        XCTAssertEqual(vm.currentUndoStack.count, 25)
        XCTAssertTrue(vm.canUndo)
        XCTAssertFalse(vm.canRedo)

        // Switch to fileB, perform edits there, and verify per-file undo isolation
        vm.openFile(at: fileB)
        XCTAssertEqual(vm.markdownText, "Initial B")
        XCTAssertFalse(vm.canUndo)
        vm.breakUndoCoalescing()
        vm.handleEditorTextEdited("Initial B\nSecond line in B", selectedRange: NSRange(location: 10, length: 0))
        XCTAssertEqual(try String(contentsOf: fileB, encoding: .utf8), "Initial B\nSecond line in B")
        XCTAssertEqual(vm.currentUndoStack.count, 1)

        // Switch back to fileA and verify all 25 undo steps are still intact
        vm.openFile(at: fileA)
        XCTAssertEqual(vm.currentUndoStack.count, 25)

        // Undo all 25 steps back to "Line 0" and verify disk is auto-saved on each undo
        for step in (0..<25).reversed() {
            vm.undo()
            let expected = (0...step).map { "Line \($0)" }.joined(separator: "\n")
            XCTAssertEqual(vm.markdownText, expected)
            XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), expected)
        }
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.canRedo)
        XCTAssertEqual(vm.currentRedoStack.count, 25)

        // Redo 10 steps
        for _ in 1...10 {
            vm.redo()
        }
        let expectedAt10 = (0...10).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(vm.markdownText, expectedAt10)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), expectedAt10)

        // Relaunch EditorWorkspaceViewModel and verify both undo (10) and redo (15) stacks persisted
        let relaunchedVM = EditorWorkspaceViewModel(userDefaults: testDefaults)
        XCTAssertEqual(relaunchedVM.currentFileURL?.standardizedFileURL, fileA.standardizedFileURL)
        XCTAssertEqual(relaunchedVM.currentUndoStack.count, 10)
        XCTAssertEqual(relaunchedVM.currentRedoStack.count, 15)
        relaunchedVM.undo()
        let expectedAt9 = (0...9).map { "Line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(relaunchedVM.markdownText, expectedAt9)
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), expectedAt9)
    }

    @MainActor
    func testEdgeCaseMidDocumentKeystrokeCoalescingAndUnicodeSurrogateCursorAnchoring() throws {
        let suiteName = "com.folio.tests.coalesceunicode.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioCoalesceUnicodeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("MiddleTyping.md")
        // File ends with a trailing newline while user types in the middle on line 2
        let initial = "# Header\n\n\nFooter line\n"
        try initial.write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.openFile(at: fileURL)

        // Simulate typing "hello world" character-by-character at offset 10 (the blank middle line)
        var text = initial
        var cursor = 10
        vm.currentSelectedRange = NSRange(location: cursor, length: 0)

        for ch in "hello" {
            let ns = text as NSString
            text = ns.replacingCharacters(in: NSRange(location: cursor, length: 0), with: String(ch))
            cursor += 1
            vm.handleEditorTextEdited(text, selectedRange: NSRange(location: cursor, length: 0))
        }
        XCTAssertEqual(vm.currentUndoStack.count, 1, "Typing 'hello' in the middle of a newline-terminated file should coalesce into 1 undo step")

        // Typing space breaks coalescing
        text = (text as NSString).replacingCharacters(in: NSRange(location: cursor, length: 0), with: " ")
        cursor += 1
        vm.handleEditorTextEdited(text, selectedRange: NSRange(location: cursor, length: 0))
        XCTAssertEqual(vm.currentUndoStack.count, 2, "Space should start a separate undo entry")

        // Typing "world" coalesces into a single word entry
        for ch in "world" {
            text = (text as NSString).replacingCharacters(in: NSRange(location: cursor, length: 0), with: String(ch))
            cursor += 1
            vm.handleEditorTextEdited(text, selectedRange: NSRange(location: cursor, length: 0))
        }
        XCTAssertEqual(vm.currentUndoStack.count, 3, "Typing 'world' should coalesce into the 3rd undo step")

        //Undo 1: removes "world", leaving "# Header\n\nhello \nFooter line\n"
        vm.undo()
        XCTAssertEqual(vm.markdownText, "# Header\n\nhello \nFooter line\n")
        XCTAssertEqual(vm.currentSelectedRange, NSRange(location: 16, length: 0))

        // Undo 2: removes " ", leaving "# Header\n\nhello\nFooter line\n"
        vm.undo()
        XCTAssertEqual(vm.markdownText, "# Header\n\nhello\nFooter line\n")
        XCTAssertEqual(vm.currentSelectedRange, NSRange(location: 15, length: 0))

        // Undo 3: removes "hello", back to initial
        vm.undo()
        XCTAssertEqual(vm.markdownText, initial)
        XCTAssertEqual(vm.currentSelectedRange, NSRange(location: 10, length: 0))

        // Now test multi-hunk cursor preservation with UTF-16 surrogate pairs (emojis 🚀🧬 & LaTeX)
        let unicodeDoc = [
            "Top line: original",
            "Unchanged separator",
            "Middle cursor line: 🚀Rocket and 🧬DNA TargetCursorHere end",
            "Unchanged separator 2",
            "Bottom line: original"
        ].joined(separator: "\n")
        try unicodeDoc.write(to: fileURL, atomically: true, encoding: .utf8)
        vm.checkForExternalFileChanges(for: fileURL)

        let targetOffsetInOld = (unicodeDoc as NSString).range(of: "TargetCursorHere").location
        vm.currentSelectedRange = NSRange(location: targetOffsetInOld, length: 16)

        // External update modifies BOTH the top and bottom of the document (inserting multi-unit emojis above)
        let unicodeUpdated = [
            "Top line: 🌟🔥✨ expanded header with emojis",
            "Extra inserted top line 🎉",
            "Unchanged separator",
            "Middle cursor line: 🚀Rocket and 🧬DNA TargetCursorHere end",
            "Unchanged separator 2",
            "Bottom line: updated footer at bottom of file"
        ].joined(separator: "\n")
        try unicodeUpdated.write(to: fileURL, atomically: true, encoding: .utf8)
        vm.checkForExternalFileChanges(for: fileURL)

        let expectedOffsetInNew = (unicodeUpdated as NSString).range(of: "TargetCursorHere").location
        XCTAssertEqual(
            vm.currentSelectedRange,
            NSRange(location: expectedOffsetInNew, length: 16),
            "Cursor in middle of document must shift by the exact UTF-16 delta of top edits even when bottom also changes"
        )

        // Verify surrogate-pair boundary clamping never splits a 2-unit UTF-16 emoji
        let emojiOnly = "🚀🧬🎉" // 6 UTF-16 code units (indices 0..1, 2..3, 4..5)
        let splitAttempt = DocumentLineDiff.adjustedSelection(
            for: NSRange(location: 1, length: 2), // index 1 and 3 are inside trail surrogates
            inOldText: emojiOnly,
            toNewText: emojiOnly
        )
        XCTAssertEqual(splitAttempt.location % 2, 0, "Adjusted selection location must never split a UTF-16 surrogate pair")
        XCTAssertEqual((splitAttempt.location + splitAttempt.length) % 2, 0, "Adjusted selection end must never split a UTF-16 surrogate pair")
    }
}
