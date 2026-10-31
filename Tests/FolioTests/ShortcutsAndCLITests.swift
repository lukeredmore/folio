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
        XCTAssertFalse(
            detector.handleFlagsChanged(
                modifierFlags: [.shift],
                timestamp: 10.00
            ))
        XCTAssertFalse(
            detector.handleFlagsChanged(
                modifierFlags: [],
                timestamp: 10.08
            ))

        // Second Shift down + up within 0.40s
        XCTAssertFalse(
            detector.handleFlagsChanged(
                modifierFlags: [.shift],
                timestamp: 10.22
            ))
        XCTAssertTrue(
            detector.handleFlagsChanged(
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
        let vm = makeIsolatedViewModel()
        vm.quickOpenQuery = "stale"
        XCTAssertFalse(vm.showQuickOpen)

        vm.toggleQuickOpen()
        XCTAssertTrue(vm.showQuickOpen)
        XCTAssertEqual(vm.quickOpenQuery, "")

        vm.toggleQuickOpen()
        XCTAssertFalse(vm.showQuickOpen)
    }

    func testShiftShiftAndEscapeKeyEventsDriveQuickOpenThroughTheEventMonitor() throws {
        let vm = makeIsolatedViewModel()
        let monitor = DoubleShiftEventMonitorAccessor.Coordinator(viewModel: vm)
        let leftShift: UInt16 = 56
        func send(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, at time: TimeInterval) throws -> NSEvent? {
            let characters = type == .flagsChanged ? "" : (keyCode == 53 ? "\u{1b}" : "a")
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: flags,
                    timestamp: time,
                    windowNumber: 0,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                ))
            return monitor.processMonitoredEvent(event)
        }

        _ = try send(.flagsChanged, [.shift], keyCode: leftShift, at: 10.00)
        _ = try send(.flagsChanged, [], keyCode: leftShift, at: 10.08)
        _ = try send(.flagsChanged, [.shift], keyCode: leftShift, at: 10.22)
        XCTAssertFalse(vm.showQuickOpen, "One Shift tap does not open Quick Open")
        _ = try send(.flagsChanged, [], keyCode: leftShift, at: 10.30)
        XCTAssertTrue(vm.showQuickOpen, "Shift-Shift opens Quick Open")

        XCTAssertNil(try send(.keyDown, [], keyCode: 53, at: 11.00), "Escape is consumed while Quick Open is open")
        XCTAssertFalse(vm.showQuickOpen, "Escape closes Quick Open")

        _ = try send(.flagsChanged, [.shift], keyCode: leftShift, at: 12.00)
        _ = try send(.flagsChanged, [], keyCode: leftShift, at: 12.08)
        XCTAssertNotNil(try send(.keyDown, [], keyCode: 0, at: 12.15), "Typing passes through the monitor")
        _ = try send(.flagsChanged, [.shift], keyCode: leftShift, at: 12.22)
        _ = try send(.flagsChanged, [], keyCode: leftShift, at: 12.30)
        XCTAssertFalse(vm.showQuickOpen, "A key typed between the Shift taps cancels Shift-Shift")
    }

    // MARK: - `folio` CLI Setup & Path Opening

    func testFolioCLIInstallOnFirstLaunchAndHelpExecution() throws {
        let defaults = isolatedDefaults()

        let tempBinDir = try makeTemporaryDirectory("folio-cli").appendingPathComponent("bin", isDirectory: true)

        let installedURL = FolioCLIManager.shared.setupCLIOnFirstLaunchIfNeeded(
            candidateBinDirs: [tempBinDir],
            appBundleURL: URL(fileURLWithPath: "/Applications/Folio.app"),
            userDefaults: defaults,
            identity: FolioAppIdentity(bundleIdentifier: FolioAppIdentity.releaseBundleIdentifier)
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

        let tempWorkspace = try makeTemporaryDirectory("folio-cli-open")

        let fileURL = tempWorkspace.appendingPathComponent("hello.md")
        try "# Hello CLI\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let vm = makeIsolatedViewModel()
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

    // MARK: - Document Find and Replace actions (menu items bound to Cmd+F and Cmd+R)

    func testDocumentFindActionsSeedQueryNavigateAndReplace() {
        let vm = makeIsolatedViewModel()
        vm.markdownText = "Alpha beta alpha GAMMA alpha"
        vm.currentSelectedRange = NSRange(location: 0, length: 5) // "Alpha"

        // Find opens without Replace controls and seeds the query from the selection
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

        // Find and Replace shows the Replace controls
        vm.openDocumentFind(withReplace: true)
        XCTAssertTrue(vm.showFindReplaceBar)
        XCTAssertTrue(vm.showDocumentReplaceControls)

        vm.replaceQuery = "Omega"
        vm.replaceCurrentMatch()
        XCTAssertEqual(vm.markdownText, "Omega beta alpha GAMMA alpha")

        vm.replaceAllInDocument()
        XCTAssertEqual(vm.markdownText, "Omega beta Omega GAMMA Omega")
    }

    // MARK: - Workspace search actions (menu items bound to Cmd+Shift+F and Cmd+Shift+R)

    func testWorkspaceSearchActionsFindAndReplaceAcrossAllFiles() throws {
        let tempDir = try makeTemporaryDirectory("folio-ws-replace")

        let fileA = tempDir.appendingPathComponent("a.md")
        let fileB = tempDir.appendingPathComponent("b.md")
        try "Project oldName overview\nSecond oldName line\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "Notes for oldName release\n".write(to: fileB, atomically: true, encoding: .utf8)

        let vm = makeIsolatedViewModel()
        vm.loadWorkspaceFolder(tempDir)
        vm.openFile(at: fileA)

        // Find in Files opens workspace search without replace
        vm.openWorkspaceSearch(withReplace: false)
        XCTAssertTrue(vm.showSidebar)
        XCTAssertEqual(vm.activeSidebarTab, .files)
        XCTAssertFalse(vm.showWorkspaceReplace)

        // Find and Replace in Files enables replace
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
        let tempDir = try makeTemporaryDirectory("folio-quickopen-path")
        let outsideDir = try makeTemporaryDirectory("folio-outside")

        let externalFile = outsideDir.appendingPathComponent("external note.md")
        try "Line 1\nLine 2\nLine 3\n".write(to: externalFile, atomically: true, encoding: .utf8)

        let vm = makeIsolatedViewModel()
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

    // MARK: - Window Mouse Event Delivery & Sidebar Toggle Regression

    func testMainWindowMouseEventsAndSidebarToggleRegression() throws {
        let vm = makeIsolatedViewModel()
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

        // 1. Regression: DoubleShiftEventMonitorAccessor must NOT access `event.keyCode` on mouse events
        // (which raises NSInternalInconsistencyException in AppKit and aborts all mouse clicks in the app).
        let monitorCoordinator = DoubleShiftEventMonitorAccessor.Coordinator(viewModel: vm)
        let clickPoint = NSPoint(x: 600, y: 500)
        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: clickPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1.0
            ))
        let rightMouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: clickPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1.0
            ))
        XCTAssertTrue(monitorCoordinator.processMonitoredEvent(mouseDown) === mouseDown)
        XCTAssertTrue(monitorCoordinator.processMonitoredEvent(rightMouseDown) === rightMouseDown)

        // 2. Hit-testing at editor center hits HybridMarkdownTextView, never background accessors
        let editorHit = hostingView.hitTest(clickPoint)
        XCTAssertNotNil(editorHit)
        XCTAssertFalse(editorHit is PassThroughAccessorNSView)
        XCTAssertTrue(
            editorHit is HybridMarkdownTextView || editorHit?.enclosingScrollView?.documentView is HybridMarkdownTextView,
            "Expected mouse click at editor center to hit HybridMarkdownTextView, got \(String(describing: editorHit))"
        )

        // 3. Toggling sidebar via textView responder action and viewModel works cleanly
        XCTAssertNotNil(vm.activeTextView)
        vm.activeTextView?.toggleSidebar(nil)
        XCTAssertFalse(vm.showSidebar)
        vm.activeTextView?.toggleSidebar(nil)
        XCTAssertTrue(vm.showSidebar)
    }
}
