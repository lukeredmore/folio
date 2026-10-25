import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class ShortcutsAndCLITests: XCTestCase {

    // MARK: - Shift-Shift (Double-Shift Quick Open)

    func testDoubleShiftDetectorTriggersOnCleanDoubleTap() {
        var detector = DoubleShiftDetector(maxHoldDuration: 0.35, maxDoubleTapInterval: 0.40)

        // First Shift down + up
        XCTAssertFalse(detector.handleFlagsChanged(
            modifierFlags: [.shift],
            timestamp: 10.00
        ))
        XCTAssertFalse(detector.handleFlagsChanged(
            modifierFlags: [],
            timestamp: 10.08
        ))

        // Second Shift down + up within 0.40s
        XCTAssertFalse(detector.handleFlagsChanged(
            modifierFlags: [.shift],
            timestamp: 10.22
        ))
        XCTAssertTrue(detector.handleFlagsChanged(
            modifierFlags: [],
            timestamp: 10.30
        ))
    }

    func testDoubleShiftDetectorCancelsOnInterveningKeyOrModifier() {
        var detector = DoubleShiftDetector(maxHoldDuration: 0.35, maxDoubleTapInterval: 0.40)

        // First Shift tap
        _ = detector.handleFlagsChanged(modifierFlags: [.shift], timestamp: 1.00)
        _ = detector.handleFlagsChanged(modifierFlags: [], timestamp: 1.05)

        // Intervening regular key press (e.g. typing a capital letter) cancels double-shift
        detector.cancelSequence()

        // Next Shift tap should NOT trigger
        _ = detector.handleFlagsChanged(modifierFlags: [.shift], timestamp: 1.15)
        XCTAssertFalse(detector.handleFlagsChanged(modifierFlags: [], timestamp: 1.20))

        // Non-shift modifier (e.g. Cmd+Shift) cancels
        _ = detector.handleFlagsChanged(modifierFlags: [.shift, .command], timestamp: 2.00)
        XCTAssertFalse(detector.handleFlagsChanged(modifierFlags: [], timestamp: 2.05))
    }

    func testToggleQuickOpenResetsQueryAndTogglesModal() {
        let suiteName = "FolioTests.QuickOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.quickOpenQuery = "stale"
        XCTAssertFalse(vm.showQuickOpen)

        vm.toggleQuickOpen()
        XCTAssertTrue(vm.showQuickOpen)
        XCTAssertEqual(vm.quickOpenQuery, "")

        vm.toggleQuickOpen()
        XCTAssertFalse(vm.showQuickOpen)
    }

    // MARK: - `folio` CLI Setup & Path Opening

    func testFolioCLIInstallOnFirstLaunchAndHelpExecution() throws {
        let suiteName = "FolioTests.CLI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempBinDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-cli-bin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBinDir) }

        let installedURL = FolioCLIManager.shared.setupCLIOnFirstLaunchIfNeeded(
            candidateBinDirs: [tempBinDir],
            appBundleURL: URL(fileURLWithPath: "/Applications/Folio.app"),
            userDefaults: defaults
        )
        let expectedScriptPath = tempBinDir.appendingPathComponent("folio").path
        XCTAssertEqual(installedURL?.path, expectedScriptPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: expectedScriptPath))

        // Running `folio --help` should succeed and print usage
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: expectedScriptPath)
        proc.arguments = ["--help"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Usage: folio"))
    }

    func testExtractCommandLinePathsAndOpenFromCLI() throws {
        let args = [
            "/Applications/Folio.app/Contents/MacOS/FolioApp",
            "-NSDocumentRevisionsDebugMode", "YES",
            "/tmp/example.md",
            "relative/notes.md"
        ]
        XCTAssertEqual(
            FolioCLIManager.extractCommandLinePaths(from: args, currentDirectoryPath: "/work"),
            ["/tmp/example.md", "/work/relative/notes.md"]
        )

        let suiteName = "FolioTests.CLIOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-cli-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempWorkspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempWorkspace) }

        let fileURL = tempWorkspace.appendingPathComponent("hello.md")
        try "# Hello CLI\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.openPathFromCLI(fileURL.path)
        XCTAssertEqual(vm.currentFileURL?.standardizedFileURL, fileURL.standardizedFileURL)
        XCTAssertEqual(vm.markdownText, "# Hello CLI\n")
        XCTAssertEqual(vm.workspaceFolderURL?.standardizedFileURL, tempWorkspace.standardizedFileURL)

        // Opening a non-existent file via `folio <new-file>` creates and opens it
        let newFileURL = tempWorkspace.appendingPathComponent("created-via-cli.md")
        vm.openPathFromCLI(newFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFileURL.path))
        XCTAssertEqual(vm.currentFileURL?.standardizedFileURL, newFileURL.standardizedFileURL)
    }

    // MARK: - Document Find (`Cmd+F`) & Find and Replace (`Cmd+R`)

    func testDocumentFindAndReplaceWorkflows() {
        let suiteName = "FolioTests.DocFind.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.markdownText = "Alpha beta alpha GAMMA alpha"
        vm.currentSelectedRange = NSRange(location: 0, length: 5) // "Alpha"

        // Cmd+F opens Find without Replace controls and seeds from selection
        vm.openDocumentFind(withReplace: false)
        XCTAssertTrue(vm.showFindReplaceBar)
        XCTAssertFalse(vm.showDocumentReplaceControls)
        XCTAssertEqual(vm.findQuery, "Alpha")
        XCTAssertEqual(vm.documentFindMatchCount, 3)

        // Find Next advances to second "alpha" at index 11
        vm.findNextInDocument()
        XCTAssertEqual(vm.currentSelectedRange, NSRange(location: 11, length: 5))

        // Find Previous returns to first "Alpha" at index 0
        vm.findPreviousInDocument()
        XCTAssertEqual(vm.currentSelectedRange, NSRange(location: 0, length: 5))

        // Cmd+R opens Find and Replace controls
        vm.openDocumentFind(withReplace: true)
        XCTAssertTrue(vm.showFindReplaceBar)
        XCTAssertTrue(vm.showDocumentReplaceControls)

        vm.replaceQuery = "Omega"
        vm.replaceCurrentMatch()
        XCTAssertEqual(vm.markdownText, "Omega beta alpha GAMMA alpha")

        vm.replaceAllInDocument()
        XCTAssertEqual(vm.markdownText, "Omega beta Omega GAMMA Omega")
    }

    // MARK: - Workspace Find (`Cmd+Shift+F`) & Replace (`Cmd+Shift+R`)

    func testWorkspaceFindAndReplaceAcrossAllFiles() throws {
        let suiteName = "FolioTests.WorkspaceFind.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-ws-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("a.md")
        let fileB = tempDir.appendingPathComponent("b.md")
        try "Project oldName overview\nSecond oldName line\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "Notes for oldName release\n".write(to: fileB, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.loadWorkspaceFolder(tempDir)
        vm.openFile(at: fileA)

        // Cmd+Shift+F opens workspace search without replace
        vm.openWorkspaceSearch(withReplace: false)
        XCTAssertTrue(vm.showSidebar)
        XCTAssertEqual(vm.activeSidebarTab, .search)
        XCTAssertFalse(vm.showWorkspaceReplace)

        // Cmd+Shift+R opens workspace search with replace enabled
        vm.openWorkspaceSearch(withReplace: true)
        XCTAssertTrue(vm.showWorkspaceReplace)

        vm.workspaceSearchQuery = "oldName"
        vm.workspaceReplaceQuery = "Folio"
        vm.performWorkspaceSearch()
        XCTAssertEqual(vm.workspaceSearchMatches.count, 3)

        let modifiedFiles = vm.replaceAllInWorkspace()
        XCTAssertEqual(modifiedFiles, 2)
        XCTAssertEqual(vm.markdownText, "Project Folio overview\nSecond Folio line\n")
        XCTAssertEqual(try String(contentsOf: fileA, encoding: .utf8), "Project Folio overview\nSecond Folio line\n")
        XCTAssertEqual(try String(contentsOf: fileB, encoding: .utf8), "Notes for Folio release\n")
        XCTAssertEqual(vm.workspaceSearchMatches.count, 0)
    }

    // MARK: - Pasting Any Path in Quick Open File Search

    func testQuickOpenPasteAnyPathAndOpen() throws {
        let suiteName = "FolioTests.QuickOpenPath.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-quickopen-path-\(UUID().uuidString)", isDirectory: true)
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let externalFile = outsideDir.appendingPathComponent("external note.md")
        try "Line 1\nLine 2\nLine 3\n".write(to: externalFile, atomically: true, encoding: .utf8)

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.loadWorkspaceFolder(tempDir)

        // 1. Pasting an external file path (even quoted or with :line suffix) opens it and jumps to line
        vm.toggleQuickOpen()
        vm.quickOpenQuery = "\"\(externalFile.path):2\""
        let candidate = vm.resolveQuickOpenPathCandidate(for: vm.quickOpenQuery)
        XCTAssertNotNil(candidate)
        XCTAssertEqual(candidate?.exists, true)
        XCTAssertEqual(candidate?.isDirectory, false)
        XCTAssertEqual(candidate?.lineNumber, 2)

        XCTAssertTrue(vm.submitQuickOpen())
        XCTAssertFalse(vm.showQuickOpen)
        XCTAssertEqual(vm.currentFileURL?.resolvingSymlinksInPath(), externalFile.resolvingSymlinksInPath())
        XCTAssertEqual(vm.markdownText, "Line 1\nLine 2\nLine 3\n")
        XCTAssertEqual(vm.currentSelectedRange.location, 7)

        // 2. Pasting a directory path opens that directory as the workspace folder
        vm.toggleQuickOpen()
        vm.quickOpenQuery = outsideDir.path
        XCTAssertTrue(vm.submitQuickOpen())
        XCTAssertFalse(vm.showQuickOpen)
        XCTAssertEqual(vm.workspaceFolderURL?.resolvingSymlinksInPath(), outsideDir.resolvingSymlinksInPath())

        // 3. Pasting a new explicit file path creates and opens it
        let newPath = outsideDir.appendingPathComponent("created-from-search.md")
        vm.toggleQuickOpen()
        vm.quickOpenQuery = newPath.path
        XCTAssertTrue(vm.submitQuickOpen())
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath.path))
        XCTAssertEqual(vm.currentFileURL?.resolvingSymlinksInPath(), newPath.resolvingSymlinksInPath())
    }

    // MARK: - Window Hit-Testing & Sidebar Toggle Regression

    func testMainWindowHitTestingAndSidebarToggleRegression() {
        let suiteName = "FolioTests.WindowHitTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        vm.markdownText = "# Title\n\nFirst paragraph line.\n\nSecond paragraph line.\n"
        vm.showSidebar = true

        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        // Background NSViewRepresentable accessors must NEVER swallow mouse clicks in the window
        let editorHit = hostingView.hitTest(NSPoint(x: 600, y: 400))
        XCTAssertNotNil(editorHit)
        XCTAssertFalse(editorHit is PassThroughAccessorNSView)
        XCTAssertTrue(
            editorHit is HybridMarkdownTextView || editorHit?.enclosingScrollView?.documentView is HybridMarkdownTextView,
            "Expected mouse click at editor center to hit HybridMarkdownTextView, got \(String(describing: editorHit))"
        )

        let statusBarHit = hostingView.hitTest(NSPoint(x: 260, y: 15))
        XCTAssertNotNil(statusBarHit)
        XCTAssertFalse(statusBarHit is PassThroughAccessorNSView)

        // Toggling sidebar via textView responder action and viewModel works cleanly
        XCTAssertNotNil(vm.activeTextView)
        vm.activeTextView?.toggleSidebar(nil)
        XCTAssertFalse(vm.showSidebar)
        vm.activeTextView?.toggleSidebar(nil)
        XCTAssertTrue(vm.showSidebar)
    }
}
