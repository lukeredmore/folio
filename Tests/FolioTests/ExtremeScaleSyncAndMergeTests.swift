import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class ExtremeScaleSyncAndMergeTests: XCTestCase {

    @MainActor
    func testExtremeMultiHunkConflictGranularResolutionAndRapidExternalStreaming() throws {
        let suiteName = "com.folio.tests.multihunkstream.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioMultiHunkStreamTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("MultiHunk.md")
        let baseDoc = [
            "Hunk 1: base",
            "Separator A",
            "Clean Local Section: base",
            "Separator B",
            "Hunk 2: base",
            "Separator C",
            "Clean External Section: base",
            "Separator D",
            "Hunk 3: base"
        ].joined(separator: "\n")
        try baseDoc.write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.openFile(at: fileURL)

        let externalDoc = [
            "Hunk 1: external",
            "Separator A",
            "Clean Local Section: base",
            "Separator B",
            "Hunk 2: external",
            "Separator C",
            "Clean External Section: auto-merged from external",
            "Separator D",
            "Hunk 3: external"
        ].joined(separator: "\n")
        try externalDoc.write(to: fileURL, atomically: true, encoding: .utf8)

        let localDoc = [
            "Hunk 1: local",
            "Separator A",
            "Clean Local Section: auto-merged from local",
            "Separator B",
            "Hunk 2: local",
            "Separator C",
            "Clean External Section: base",
            "Separator D",
            "Hunk 3: local"
        ].joined(separator: "\n")
        vm.handleEditorTextEdited(localDoc, selectedRange: NSRange(location: 0, length: 0))

        guard let conflict = vm.activeConflict else {
            XCTFail("Expected 3-hunk conflict")
            return
        }
        XCTAssertEqual(conflict.conflictHunks.count, 3)

        // Resolve Hunk 0 with .keepLocal, Hunk 1 with .acceptExternal, Hunk 2 with .keepBoth
        vm.setConflictHunkResolution(.keepLocal, forHunkID: conflict.conflictHunks[0].id)
        vm.setConflictHunkResolution(.acceptExternal, forHunkID: conflict.conflictHunks[1].id)
        vm.setConflictHunkResolution(.keepBoth, forHunkID: conflict.conflictHunks[2].id)
        vm.applyInteractiveConflictResolution()
        XCTAssertNil(vm.activeConflict)

        let expectedGranularMerge = [
            "Hunk 1: local",
            "Separator A",
            "Clean Local Section: auto-merged from local",
            "Separator B",
            "Hunk 2: external",
            "Separator C",
            "Clean External Section: auto-merged from external",
            "Separator D",
            "Hunk 3: local",
            "Hunk 3: external"
        ].joined(separator: "\n")
        XCTAssertEqual(vm.markdownText, expectedGranularMerge)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), expectedGranularMerge)

        // Now simulate a rapid burst of 60 external streaming writes (mixing in-place and atomic writes)
        for i in 1...60 {
            let streamText = expectedGranularMerge + "\nStreamed token #\(i)"
            if i % 2 == 0 {
                try streamText.write(to: fileURL, atomically: true, encoding: .utf8)
            } else {
                try Data(streamText.utf8).write(to: fileURL)
            }
            vm.checkForExternalFileChanges(for: fileURL)
            XCTAssertEqual(vm.markdownText, streamText)
        }

        // Undo all 60 streamed external updates and verify we land right back at expectedGranularMerge
        for _ in 1...60 {
            vm.undo()
        }
        XCTAssertEqual(vm.markdownText, expectedGranularMerge)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), expectedGranularMerge)
    }

    @MainActor
    func testExtremeScale1000StepInfiniteUndoRedoAnd5000LineThreeWayMergePerformance() throws {
        let suiteName = "com.folio.tests.extremescale.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioExtremeScaleTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // PART 1: 1,000-step infinite undo & redo stress test with live autosave on every step
        let stressFile = tempDir.appendingPathComponent("Stress1000.md")
        try "Step 0".write(to: stressFile, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.openFile(at: stressFile)

        let totalSteps = 1_000
        let tEditStart = CFAbsoluteTimeGetCurrent()
        for step in 1...totalSteps {
            vm.breakUndoCoalescing()
            let updated = "Step \(step) — payload line with markdown **bold** and `code`"
            vm.handleEditorTextEdited(updated, selectedRange: NSRange(location: (updated as NSString).length, length: 0))
        }
        let editElapsed = CFAbsoluteTimeGetCurrent() - tEditStart

        XCTAssertEqual(vm.currentUndoStack.count, totalSteps, "In-memory undo timeline must hold all 1,000 steps without truncation")
        XCTAssertFalse(vm.isDirty)
        XCTAssertEqual(
            try String(contentsOf: stressFile, encoding: .utf8),
            "Step \(totalSteps) — payload line with markdown **bold** and `code`"
        )

        let tUndoStart = CFAbsoluteTimeGetCurrent()
        for _ in 1...totalSteps {
            vm.undo()
        }
        let undoElapsed = CFAbsoluteTimeGetCurrent() - tUndoStart

        XCTAssertEqual(vm.markdownText, "Step 0")
        XCTAssertEqual(try String(contentsOf: stressFile, encoding: .utf8), "Step 0")
        XCTAssertFalse(vm.canUndo)
        XCTAssertEqual(vm.currentRedoStack.count, totalSteps)

        let tRedoStart = CFAbsoluteTimeGetCurrent()
        for _ in 1...totalSteps {
            vm.redo()
        }
        let redoElapsed = CFAbsoluteTimeGetCurrent() - tRedoStart

        XCTAssertEqual(vm.markdownText, "Step \(totalSteps) — payload line with markdown **bold** and `code`")
        XCTAssertEqual(
            try String(contentsOf: stressFile, encoding: .utf8),
            "Step \(totalSteps) — payload line with markdown **bold** and `code`"
        )
        XCTAssertFalse(vm.canRedo)
        XCTAssertLessThan(editElapsed, 5.0, "1,000 edits + disk autosaves + undo persistence should finish in <5s (took \(editElapsed)s)")
        XCTAssertLessThan(undoElapsed, 5.0, "1,000 undos + disk autosaves should finish in <5s (took \(undoElapsed)s)")
        XCTAssertLessThan(redoElapsed, 5.0, "1,000 redos + disk autosaves should finish in <5s (took \(redoElapsed)s)")

        // PART 2: 5,000-line document 3-way auto-merge & line-diff performance benchmark
        let lineCount = 5_000
        let baseLines = (0..<lineCount).map { "### Section \($0): Unique baseline content for paragraph \($0)" }
        var localLines = baseLines
        localLines[25] = "### Section 25: Modified locally near top of 5,000-line document"
        localLines[2500] = "### Section 2500: Modified locally in exact middle of 5,000-line document"

        var externalLines = baseLines
        externalLines[4975] = "### Section 4975: Modified externally near bottom of 5,000-line document"
        externalLines.append("### Section 5000: Appended externally at end of file")

        let base5000 = baseLines.joined(separator: "\n")
        let local5000 = localLines.joined(separator: "\n")
        let external5000 = externalLines.joined(separator: "\n")

        let tMergeStart = CFAbsoluteTimeGetCurrent()
        let mergeResult = ThreeWayDocumentMerger.merge(
            base: base5000,
            local: local5000,
            external: external5000,
            fileURL: stressFile
        )
        let diffResult = DocumentLineDiff.computeDiff(from: base5000, to: external5000)
        let adjustedCursor = DocumentLineDiff.adjustedSelection(
            for: NSRange(location: 60_000, length: 12),
            inOldText: base5000,
            toNewText: external5000
        )
        let mergeElapsed = CFAbsoluteTimeGetCurrent() - tMergeStart

        guard case .clean(let merged5000, let wasAutoMerged) = mergeResult else {
            XCTFail("5,000-line disjoint 3-way merge should succeed cleanly")
            return
        }
        XCTAssertTrue(wasAutoMerged)
        XCTAssertTrue(merged5000.contains("### Section 25: Modified locally near top"))
        XCTAssertTrue(merged5000.contains("### Section 2500: Modified locally in exact middle"))
        XCTAssertTrue(merged5000.contains("### Section 4975: Modified externally near bottom"))
        XCTAssertTrue(merged5000.contains("### Section 5000: Appended externally at end of file"))
        XCTAssertEqual(diffResult.addedLinesCount, 2)
        XCTAssertEqual(diffResult.removedLinesCount, 1)
        XCTAssertEqual(adjustedCursor, NSRange(location: 60_000, length: 12))
        XCTAssertLessThan(mergeElapsed, 0.15, "5,000-line 3-way auto-merge + line diff + cursor anchoring should complete in <150ms (took \(mergeElapsed * 1000)ms)")

        print(String(
            format: "[FolioPerf] 1000 edits=%.1fms (%.2fms/op), 1000 undos=%.1fms (%.2fms/op), 1000 redos=%.1fms (%.2fms/op), 5000-line 3-way merge+diff=%.2fms",
            editElapsed * 1000, editElapsed,
            undoElapsed * 1000, undoElapsed,
            redoElapsed * 1000, redoElapsed,
            mergeElapsed * 1000
        ))
    }
}
