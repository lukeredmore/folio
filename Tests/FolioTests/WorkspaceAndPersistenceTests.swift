import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class WorkspaceAndPersistenceTests: XCTestCase {

    @MainActor
    func testFilesViewerHidesNonMarkdownFiles() throws {
        let tempDir = try makeTemporaryDirectory("FolioFilterTest")

        // Create Markdown files, non-Markdown files (.swift, .yaml, .json), and an empty/code-only subdir
        let readmeURL = tempDir.appendingPathComponent("README.md")
        let notesURL = tempDir.appendingPathComponent("guide.markdown")
        let swiftURL = tempDir.appendingPathComponent("main.swift")
        let yamlURL = tempDir.appendingPathComponent("config.yaml")

        let docsSubdir = tempDir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsSubdir, withIntermediateDirectories: true)
        let archURL = docsSubdir.appendingPathComponent("architecture.md")
        let helperSwiftURL = docsSubdir.appendingPathComponent("helper.swift")

        let codeOnlySubdir = tempDir.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: codeOnlySubdir, withIntermediateDirectories: true)
        let appSwiftURL = codeOnlySubdir.appendingPathComponent("App.swift")

        try "# Readme".write(to: readmeURL, atomically: true, encoding: .utf8)
        try "# Guide".write(to: notesURL, atomically: true, encoding: .utf8)
        try "import Foundation".write(to: swiftURL, atomically: true, encoding: .utf8)
        try "key: value".write(to: yamlURL, atomically: true, encoding: .utf8)
        try "# Architecture".write(to: archURL, atomically: true, encoding: .utf8)
        try "struct Helper {}".write(to: helperSwiftURL, atomically: true, encoding: .utf8)
        try "struct App {}".write(to: appSwiftURL, atomically: true, encoding: .utf8)

        let vm = makeIsolatedViewModel()

        vm.autoSaveDelay = 0
        vm.loadWorkspaceFolder(tempDir)

        // Flat list should only contain the 3 Markdown files
        let flatNames = Set(vm.flatMarkdownFiles.map(\.name))
        XCTAssertEqual(flatNames, ["README.md", "guide.markdown", "architecture.md"])
        XCTAssertFalse(flatNames.contains("main.swift"))
        XCTAssertFalse(flatNames.contains("config.yaml"))

        // The folder is one sidebar root. Its children are only "docs", "README.md", and "guide.markdown"
        // (no "main.swift", no "config.yaml", and no "Sources" directory since it has no Markdown files)
        XCTAssertEqual(vm.rootFileNodes.count, 1)
        let folderRoot = try XCTUnwrap(vm.rootFileNodes.first)
        XCTAssertTrue(folderRoot.isLocalRoot)
        let rootChildren = folderRoot.children ?? []
        XCTAssertEqual(Set(rootChildren.map(\.name)), ["docs", "README.md", "guide.markdown"])

        if let docsNode = rootChildren.first(where: { $0.name == "docs" }) {
            let docsChildrenNames = Set((docsNode.children ?? []).map(\.name))
            XCTAssertEqual(docsChildrenNames, ["architecture.md"])
        } else {
            XCTFail("Expected 'docs' directory node in rootFileNodes")
        }
    }

    @MainActor
    func testWorkspaceFolderAndSessionStatePersistenceAcrossLaunches() throws {
        let tempDir = try makeTemporaryDirectory("FolioPersistenceTest")
        let subfolderDir = tempDir.appendingPathComponent("Subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolderDir, withIntermediateDirectories: true)

        let fileA = tempDir.appendingPathComponent("Alpha.md")
        let fileB = subfolderDir.appendingPathComponent("Beta.md")
        try "# Alpha Heading\nFirst document body.\n\n## Alpha Subheading\nDetails here.".write(to: fileA, atomically: true, encoding: .utf8)
        try "# Beta Heading\nSecond document in subfolder.".write(to: fileB, atomically: true, encoding: .utf8)

        let testDefaults = isolatedDefaults()

        // 1. Launch #1: Configure workspace folder, open file, sidebar state, collapsed folders, theme, and editor modes
        do {
            let vm1 = makeIsolatedViewModel(defaults: testDefaults)
            vm1.autoSaveDelay = 0
            vm1.loadWorkspaceFolder(tempDir)
            vm1.openFile(at: fileA)
            vm1.openFile(at: fileB)
            vm1.updateSelectionStats(selectedRange: NSRange(location: 16, length: 0))

            vm1.theme = .midnight
            vm1.sourceCodeMode = true
            vm1.focusMode = true
            vm1.typewriterMode = true
            vm1.spellCheckEnabled = true
            vm1.showSidebar = true
            vm1.activeSidebarTab = .files
            vm1.fileDisplayStyle = .list
            vm1.fileSortOrder = .modificationDate
            vm1.setDirectoryExpanded(false, for: subfolderDir)
        }

        // 2. Launch #2: Verify full state restoration from UserDefaults
        do {
            let vm2 = makeIsolatedViewModel(defaults: testDefaults)
            vm2.autoSaveDelay = 0
            XCTAssertEqual(vm2.workspaceFolderURL?.standardizedFileURL, tempDir.standardizedFileURL)
            XCTAssertEqual(Set(vm2.flatMarkdownFiles.map(\.name)), ["Alpha.md", "Beta.md"])
            XCTAssertEqual(vm2.currentFileURL?.standardizedFileURL, fileB.standardizedFileURL)
            XCTAssertEqual(vm2.markdownText, "# Beta Heading\nSecond document in subfolder.")
            XCTAssertFalse(vm2.isDirty)
            XCTAssertEqual(vm2.documentTitle, "Beta.md")
            XCTAssertEqual(vm2.headings.map(\.title), ["Beta Heading"])
            XCTAssertEqual(vm2.pendingScrollToCharacterLocation, 16)

            XCTAssertEqual(vm2.theme, .midnight)
            XCTAssertTrue(vm2.sourceCodeMode)
            XCTAssertTrue(vm2.focusMode)
            XCTAssertTrue(vm2.typewriterMode)
            XCTAssertTrue(vm2.spellCheckEnabled)
            XCTAssertTrue(vm2.showSidebar)
            XCTAssertEqual(vm2.activeSidebarTab, .files)
            XCTAssertEqual(vm2.fileDisplayStyle, .list)
            XCTAssertEqual(vm2.fileSortOrder, .modificationDate)
            XCTAssertFalse(vm2.isDirectoryExpanded(subfolderDir))
            XCTAssertEqual(vm2.recentFileURLs.map(\.lastPathComponent), ["Beta.md", "Alpha.md"])

            // Make edits to the open file — verify they are automatically saved to disk immediately
            vm2.handleEditorTextEdited(
                "# Beta Heading\nAuto-saved edit across relaunch!",
                selectedRange: NSRange(location: 25, length: 0)
            )
            XCTAssertFalse(vm2.isDirty, "Open file edits should auto-save immediately with no dirty state")
            XCTAssertEqual(
                try String(contentsOf: fileB, encoding: .utf8),
                "# Beta Heading\nAuto-saved edit across relaunch!"
            )
        }

        // 3. Launch #3: Verify auto-saved file and its undo history are restored intact across relaunch
        do {
            let vm3 = makeIsolatedViewModel(defaults: testDefaults)
            vm3.autoSaveDelay = 0
            XCTAssertEqual(vm3.currentFileURL?.standardizedFileURL, fileB.standardizedFileURL)
            XCTAssertEqual(vm3.markdownText, "# Beta Heading\nAuto-saved edit across relaunch!")
            XCTAssertFalse(vm3.isDirty)
            XCTAssertEqual(vm3.pendingScrollToCharacterLocation, 25)
            XCTAssertTrue(vm3.canUndo, "Undo timeline should persist across app launches")

            // Now create a brand-new untitled draft and type into it without choosing a file path
            vm3.newDocument()
            vm3.handleEditorTextEdited(
                "# Scratchpad Draft\nRemember this untitled note on relaunch.",
                selectedRange: NSRange(location: 19, length: 0)
            )
        }

        // 4. Launch #4: Verify untitled draft session is restored intact
        do {
            let vm4 = makeIsolatedViewModel(defaults: testDefaults)
            vm4.autoSaveDelay = 0
            XCTAssertNil(vm4.currentFileURL)
            XCTAssertEqual(vm4.markdownText, "# Scratchpad Draft\nRemember this untitled note on relaunch.")
            XCTAssertFalse(vm4.isDirty)
            XCTAssertEqual(vm4.documentTitle, "Scratchpad Draft.md")
            XCTAssertEqual(vm4.pendingScrollToCharacterLocation, 19)

            // Open fileA cleanly, then delete tempDir to verify deleted folder/file fallback
            vm4.openFile(at: fileA)
            XCTAssertFalse(vm4.isDirty)
        }

        // 5. Delete the workspace folder on disk and verify Launch #5 falls back gracefully without crashing
        try FileManager.default.removeItem(at: tempDir)
        do {
            let vm5 = makeIsolatedViewModel(defaults: testDefaults)
            vm5.autoSaveDelay = 0
            XCTAssertNotEqual(vm5.workspaceFolderURL?.standardizedFileURL, tempDir.standardizedFileURL)
            XCTAssertNil(vm5.currentFileURL)
            XCTAssertEqual(vm5.markdownText, EditorWorkspaceViewModel.defaultWelcomeDocument)
            XCTAssertFalse(vm5.isDirty)
            XCTAssertTrue(vm5.recentFileURLs.isEmpty)
        }

        // 6. Verify app delegate quits when the last window is closed
        let appDelegate = FolioAppDelegate()
        XCTAssertTrue(appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @MainActor
    func testMainWindowMouseClickPlacesCursorAndTogglesSidebarThroughEventQueue() throws {
        let vm = makeIsolatedViewModel()
        vm.autoSaveDelay = 0
        vm.markdownText = "# Heading Line\n\nSecond paragraph with clickable text.\n\nThird paragraph at bottom.\n"
        vm.showSidebar = true

        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(vm.activeTextView, "MainWindowView should attach an active HybridMarkdownTextView")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.selectedRange().location, 0)

        // Compute window coordinates for the start of "Third paragraph at bottom." inside HybridMarkdownTextView
        let nsText = textView.string as NSString
        let thirdParaRange = nsText.range(of: "Third paragraph")
        XCTAssertNotEqual(thirdParaRange.location, NSNotFound)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: thirdParaRange.location, length: 1), actualCharacterRange: nil)
        let glyphRectInContainer = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let pointInTextView = NSPoint(
            x: textView.textContainerInset.width + glyphRectInContainer.midX,
            y: textView.textContainerInset.height + glyphRectInContainer.midY
        )
        let pointInWindow = textView.convert(pointInTextView, to: nil)

        // 1. Verify hitTest at the target editor point resolves to HybridMarkdownTextView (not a background NSView)
        let hitView = hostingView.hitTest(pointInWindow)
        XCTAssertTrue(
            hitView === textView,
            "Expected hitTest at editor paragraph to return HybridMarkdownTextView, got \(String(describing: hitView))"
        )

        // Helper that posts a real mouse click through NSApp's event queue (running all local NSEvent monitors)
        // and dispatches it to the window. Note: NSTextView.mouseDown runs an internal tracking loop waiting
        // for .leftMouseUp, so .leftMouseUp must be queued BEFORE calling window.sendEvent(down).
        var nextEventNumber = 100
        func sendLeftClick(at point: NSPoint) throws {
            while NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) != nil {}
            nextEventNumber += 1
            let down = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: nextEventNumber, clickCount: 1, pressure: 1.0
                ))
            nextEventNumber += 1
            let up = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: nextEventNumber, clickCount: 1, pressure: 0.0
                ))
            NSApp.postEvent(up, atStart: true)
            NSApp.postEvent(down, atStart: true)
            let dequeuedDown = try XCTUnwrap(
                NSApp.nextEvent(matching: .leftMouseDown, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true),
                "Left mouse down must survive local NSEvent monitors without throwing or being swallowed"
            )
            let hitTarget = try XCTUnwrap(window.contentView?.superview?.hitTest(dequeuedDown.locationInWindow))
            NSApp.sendEvent(dequeuedDown)
            if !NSApp.isActive && !hitTarget.acceptsFirstMouse(for: dequeuedDown) {
                if hitTarget.acceptsFirstResponder {
                    _ = window.makeFirstResponder(hitTarget)
                }
                hitTarget.mouseDown(with: dequeuedDown)
            }
            if let remainingUp = NSApp.nextEvent(matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true) {
                NSApp.sendEvent(remainingUp)
            }
        }

        // 2. Verify right-click and left-click in editor survive local NSEvent monitors and move the insertion cursor
        let rightDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: pointInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil,
                eventNumber: 99, clickCount: 1, pressure: 1.0
            ))
        NSApp.sendEvent(rightDown)

        try sendLeftClick(at: pointInWindow)
        XCTAssertGreaterThanOrEqual(
            textView.selectedRange().location,
            thirdParaRange.location,
            "Mouse click inside HybridMarkdownTextView must move the insertion cursor to the clicked paragraph"
        )

        // 3. Click the StatusBarView source code toggle button via NSApp event queue + window.sendEvent
        let detailOriginInWindow = (textView.enclosingScrollView ?? textView).convert(NSPoint.zero, to: nil)
        XCTAssertFalse(vm.sourceCodeMode)
        try sendLeftClick(at: NSPoint(x: detailOriginInWindow.x + 20, y: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(vm.sourceCodeMode, "Clicking the StatusBar source code button must toggle sourceCodeMode (detailOriginX=\(detailOriginInWindow.x))")

        try sendLeftClick(at: NSPoint(x: detailOriginInWindow.x + 20, y: 15))
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertFalse(vm.sourceCodeMode, "Clicking the StatusBar source code button again must exit sourceCodeMode")
    }

    @MainActor
    func testProfileSidebarResizeAnimationLatency() throws {
        let vm = makeIsolatedViewModel()
        let hosting = NSHostingView(rootView: HybridMarkdownEditorRepresentable(viewModel: vm))
        hosting.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        hosting.layoutSubtreeIfNeeded()

        guard let tv = vm.activeTextView, let sv = tv.enclosingScrollView else {
            return XCTFail("Expected activeTextView and enclosingScrollView")
        }

        // Simulate 60 animation frames of NSSplitViewController resizing the editor pane
        // from 1000pt (sidebar collapsed) down to 735pt (sidebar expanded, 265pt wide) and back.
        let steps = 30
        var widths: [CGFloat] = []
        for i in 1...steps {
            widths.append(1000.0 - CGFloat(i) * (265.0 / CGFloat(steps)))
        }
        for i in 1...steps {
            widths.append(735.0 + CGFloat(i) * (265.0 / CGFloat(steps)))
        }

        let start = CFAbsoluteTimeGetCurrent()
        for w in widths {
            sv.setFrameSize(NSSize(width: w, height: 700))
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let avgFrameMs = elapsedMs / Double(widths.count)
        XCTAssertLessThan(
            avgFrameMs,
            10.0,
            String(format: "Sidebar resize animation frame budget exceeded: %.2f ms/frame (%.2f ms total)", avgFrameMs, elapsedMs)
        )
        let viewportWidth = max(sv.contentView.bounds.width, 320)
        let proseWidth = min(max(viewportWidth - 72, 200), vm.typography.maxColumnWidth)
        let expectedInset = max((viewportWidth - proseWidth) / 2.0, 36.0)
        XCTAssertEqual(tv.textContainerOrigin.x, expectedInset, accuracy: 0.5)
    }
}
