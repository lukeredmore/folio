import Darwin
import Foundation
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

@MainActor
final class StartupResourceLimitsTests: XCTestCase {

    func testRaiseOpenFileLimitRecoversFromSimulatedLaunchd256SoftLimit() {
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        defer {
            var restored = original
            _ = setrlimit(RLIMIT_NOFILE, &restored)
        }

        // Simulate launchd's default 256 soft limit for GUI applications on macOS.
        var simulatedLaunchd = rlimit(rlim_cur: 256, rlim_max: original.rlim_max)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &simulatedLaunchd), 0)

        let raised = FolioProcessLimits.raiseOpenFileLimitIfNeeded()
        XCTAssertGreaterThanOrEqual(raised, Int(OPEN_MAX))
        XCTAssertGreaterThanOrEqual(FolioProcessLimits.currentSoftOpenFileLimit(), Int(OPEN_MAX))
    }

    func testUndoTimelineStoreMigratesLegacyUserDefaultsBlobToFileAndPurgesDefaultsKey() throws {
        let defaults = isolatedDefaults()
        let storageDir = try makeTemporaryDirectory("UndoTimelineStorage")
        let storageFileURL = storageDir.appendingPathComponent("undo_timelines.json")
        let key = EditorWorkspaceViewModel.undoTimelinesDefaultsKey

        let docPath = storageDir.appendingPathComponent("RestoredNote.md").standardizedFileURL.path
        try "Updated line".write(toFile: docPath, atomically: true, encoding: .utf8)

        let legacyEntry = DocumentUndoEntry(
            previousText: "Original line",
            newText: "Updated line",
            previousSelectedRange: NSRange(location: 0, length: 0),
            newSelectedRange: NSRange(location: 12, length: 0),
            origin: .userTyping,
            summary: "Typing"
        )
        let legacyTimelines: [String: DocumentUndoTimeline] = [
            docPath: DocumentUndoTimeline(undoStack: [legacyEntry], redoStack: [])
        ]
        let legacyData = try JSONEncoder().encode(legacyTimelines)
        defaults.set(legacyData, forKey: key)
        XCTAssertNotNil(defaults.data(forKey: key))

        let store = UndoTimelineStore(storageFileURL: storageFileURL)
        let vm = EditorWorkspaceViewModel(
            remoteWorkspaceManager: RemoteWorkspaceManager(
                mirrorBaseDirectory: try makeTemporaryDirectory("UndoMigrationMirror"),
                userDefaults: defaults
            ),
            userDefaults: defaults,
            undoTimelineStore: store
        )
        defer {
            vm.stopWatchingCurrentFile()
            vm.stopWatchingWorkspaceFolders()
        }

        // Legacy key must be removed from UserDefaults and migrated into undo_timelines.json.
        XCTAssertNil(defaults.object(forKey: key), "Legacy undo timelines blob must be purged from UserDefaults after migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageFileURL.path))

        vm.openFile(at: URL(fileURLWithPath: docPath))
        XCTAssertTrue(vm.canUndo)
        vm.undo()
        XCTAssertEqual(vm.markdownText, "Original line")

        // Relaunch with a fresh UndoTimelineStore pointed at the same file and verify persistence without UserDefaults.
        let relaunchedStore = UndoTimelineStore(storageFileURL: storageFileURL)
        relaunchedStore.loadIfNeeded(from: defaults, defaultsKey: key)
        XCTAssertEqual(relaunchedStore.timelines[docPath]?.redoStack.count, 1)
        XCTAssertNil(defaults.object(forKey: key))
    }

    func testUndoTimelineBoundingCapsByteBudgetAndKeepsMostRecentFiles() {
        let largeChunk = String(repeating: "x", count: 200_000)
        var timelines: [String: DocumentUndoTimeline] = [:]
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for fileIndex in 0..<40 {
            let entry = DocumentUndoEntry(
                previousText: largeChunk,
                newText: largeChunk + "\nedit \(fileIndex)",
                timestamp: baseDate.addingTimeInterval(TimeInterval(fileIndex)),
                origin: .userTyping
            )
            timelines["/docs/file-\(fileIndex).md"] = DocumentUndoTimeline(undoStack: [entry], redoStack: [])
        }

        let bounded = UndoTimelineStore.boundedTimelines(
            timelines,
            maxEntriesPerFile: 100,
            maxFiles: 32,
            maxEstimatedUTF8Bytes: UndoTimelineStore.maxUserDefaultsUTF8Bytes
        )

        XCTAssertTrue(bounded.keys.contains("/docs/file-39.md"), "Newest edited file must be retained")
        XCTAssertFalse(bounded.keys.contains("/docs/file-0.md"), "Oldest files beyond budget must be pruned")
        if let encoded = try? JSONEncoder().encode(bounded) {
            XCTAssertLessThan(encoded.count, 4_194_304, "Encoded timelines must stay strictly below CFPreferences 4 MB limit")
        } else {
            XCTFail("Failed to encode bounded timelines")
        }
    }
}
