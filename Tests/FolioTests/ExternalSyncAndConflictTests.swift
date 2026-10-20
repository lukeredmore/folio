import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class ExternalSyncAndConflictTests: XCTestCase {

    @MainActor
    func testLiveExternalFileAutoUpdateInPlaceAndAtomicWithVisualNoticeAndUndo() throws {
        let suiteName = "com.folio.tests.externalupdate.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioExternalUpdateTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("LiveDoc.md")
        let initialText = "# Live Document\n\nParagraph one.\n\nParagraph two."
        try initialText.write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)

        vm.autoSaveDelay = 0
        vm.openFile(at: fileURL)
        XCTAssertEqual(vm.markdownText, initialText)
        XCTAssertNil(vm.externalUpdateNotice)

        // Simulate an external atomic write (like vim/sed/git/Claude editing the file on disk)
        let externallyUpdatedText = "# Live Document\n\nParagraph one (updated externally!).\n\nParagraph two.\n\n### Added Section"
        try externallyUpdatedText.write(to: fileURL, atomically: true, encoding: .utf8)
        vm.checkForExternalFileChanges(for: fileURL)

        XCTAssertEqual(vm.markdownText, externallyUpdatedText)
        XCTAssertNotNil(vm.externalUpdateNotice, "Visual external update notice should be published")
        XCTAssertEqual(vm.externalUpdateNotice?.wasThreeWayMerged, false)
        XCTAssertGreaterThan(vm.externalUpdateNotice?.addedLines ?? 0, 0)
        XCTAssertFalse(vm.externalUpdateHighlightRanges.isEmpty, "Changed line ranges should be highlighted in the editor")

        // Verify the external update itself is undoable with Cmd+Z!
        XCTAssertTrue(vm.canUndo)
        XCTAssertEqual(vm.currentUndoStack.last?.origin, .externalUpdate)
        vm.undo()
        XCTAssertEqual(vm.markdownText, initialText)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), initialText)

        // And redoable with Cmd+Shift+Z!
        vm.redo()
        XCTAssertEqual(vm.markdownText, externallyUpdatedText)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), externallyUpdatedText)
    }

    @MainActor
    func testThreeWayAutoMergeAndInteractiveConflictResolution() throws {
        let suiteName = "com.folio.tests.conflictmerge.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioConflictMergeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let fileURL = tempDir.appendingPathComponent("Collab.md")
        let baseText = [
            "# Shared Spec",
            "",
            "Section Alpha: original",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: original"
        ].joined(separator: "\n")
        try baseText.write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)

        vm.autoSaveDelay = 0
        vm.openFile(at: fileURL)

        // 1. Test clean 3-way auto-merge when local and external edit different sections concurrently:
        // External tool updates Section Gamma on disk BEFORE local edit flushes
        let externalDisjoint = [
            "# Shared Spec",
            "",
            "Section Alpha: original",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: updated by external agent"
        ].joined(separator: "\n")
        try externalDisjoint.write(to: fileURL, atomically: true, encoding: .utf8)

        // User edits Section Alpha locally in Folio — pre-write check detects disk changed and auto-merges!
        let localDisjoint = [
            "# Shared Spec",
            "",
            "Section Alpha: edited locally in Folio",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: original"
        ].joined(separator: "\n")
        vm.handleEditorTextEdited(localDisjoint, selectedRange: NSRange(location: 20, length: 0))

        let expectedMerged = [
            "# Shared Spec",
            "",
            "Section Alpha: edited locally in Folio",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: updated by external agent"
        ].joined(separator: "\n")
        XCTAssertNil(vm.activeConflict, "Disjoint concurrent edits should auto-merge cleanly without conflict")
        XCTAssertEqual(vm.markdownText, expectedMerged)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), expectedMerged)
        XCTAssertEqual(vm.externalUpdateNotice?.wasThreeWayMerged, true)

        // 2. Test overlapping conflict detection and resolution:
        // External process modifies Section Alpha on disk while user ALSO modifies Section Alpha locally
        let externalConflicting = [
            "# Shared Spec",
            "",
            "Section Alpha: EXTERNAL OVERRIDE",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: updated by external agent"
        ].joined(separator: "\n")
        try externalConflicting.write(to: fileURL, atomically: true, encoding: .utf8)

        let localConflicting = [
            "# Shared Spec",
            "",
            "Section Alpha: LOCAL OVERRIDE",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: updated by external agent"
        ].joined(separator: "\n")
        vm.handleEditorTextEdited(localConflicting, selectedRange: NSRange(location: 20, length: 0))

        XCTAssertNotNil(vm.activeConflict, "Overlapping concurrent edits must surface an active conflict")
        XCTAssertEqual(vm.activeConflict?.conflictHunks.count, 1)
        XCTAssertEqual(vm.activeConflict?.conflictHunks.first?.localLines, ["Section Alpha: LOCAL OVERRIDE"])
        XCTAssertEqual(vm.activeConflict?.conflictHunks.first?.externalLines, ["Section Alpha: EXTERNAL OVERRIDE"])

        // Resolve conflict using .keepBoth and verify result is auto-saved and undoable
        vm.resolveConflict(using: .keepBoth)
        XCTAssertNil(vm.activeConflict)
        let expectedKeepBoth = [
            "# Shared Spec",
            "",
            "Section Alpha: LOCAL OVERRIDE",
            "Section Alpha: EXTERNAL OVERRIDE",
            "",
            "Section Beta: unchanged middle",
            "",
            "Section Gamma: updated by external agent"
        ].joined(separator: "\n")
        XCTAssertEqual(vm.markdownText, expectedKeepBoth)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), expectedKeepBoth)

        // Undo the conflict resolution and verify it restores the pre-resolution local buffer
        vm.undo()
        XCTAssertEqual(vm.markdownText, localConflicting)
    }

    @MainActor
    func testEdgeCaseEmptyFileTruncationsNewlinesAndIdempotentConcurrentEdits() throws {
        let suiteName = "com.folio.tests.edgecases.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioEdgeCasesTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Initially empty file ("") modified both externally and locally -> must detect conflict!
        let emptyFile = tempDir.appendingPathComponent("EmptyStart.md")
        try "".write(to: emptyFile, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)

        vm.autoSaveDelay = 0
        vm.openFile(at: emptyFile)
        XCTAssertEqual(vm.markdownText, "")

        try "External first line".write(to: emptyFile, atomically: true, encoding: .utf8)
        vm.handleEditorTextEdited("Local first line", selectedRange: NSRange(location: 16, length: 0))
        XCTAssertNotNil(vm.activeConflict, "Concurrent edits starting from an empty file must detect conflict instead of overwriting")

        // Self-healing conflict: if the external file on disk is updated to match local, conflict auto-clears
        try "Local first line".write(to: emptyFile, atomically: true, encoding: .utf8)
        vm.checkForExternalFileChanges(for: emptyFile)
        XCTAssertNil(vm.activeConflict, "Conflict should self-heal when external file matches local buffer")
        XCTAssertFalse(vm.isDirty)

        // 2. External truncation to completely empty file ("") and undo back to previous text
        try "".write(to: emptyFile, atomically: true, encoding: .utf8)
        vm.checkForExternalFileChanges(for: emptyFile)
        XCTAssertEqual(vm.markdownText, "")
        XCTAssertNotNil(vm.externalUpdateNotice)
        vm.undo()
        XCTAssertEqual(vm.markdownText, "Local first line")
        XCTAssertEqual(try String(contentsOf: emptyFile, encoding: .utf8), "Local first line")

        // 3. Idempotent concurrent edits (local and external make the exact same edit to the same line)
        let idempotentBase = "Line 1\nLine 2\nLine 3\n"
        try idempotentBase.write(to: emptyFile, atomically: true, encoding: .utf8)
        vm.checkForExternalFileChanges(for: emptyFile)
        XCTAssertEqual(vm.markdownText, idempotentBase)

        let identicalModification = "Line 1\nLine 2 — modified identically by both!\nLine 3\n"
        try identicalModification.write(to: emptyFile, atomically: true, encoding: .utf8)
        vm.handleEditorTextEdited(identicalModification, selectedRange: NSRange(location: 10, length: 0))
        XCTAssertNil(vm.activeConflict, "Identical concurrent modifications to the same line must merge cleanly without false conflict")
        XCTAssertEqual(vm.markdownText, identicalModification)
    }
}
