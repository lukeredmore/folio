import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class WorkspaceAndPersistenceTests: XCTestCase {

    @MainActor
    func testFilesViewerHidesNonMarkdownFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FolioFilterTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

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

        let defaultsSuiteName = "com.folio.tests.filter.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { testDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)

        vm.autoSaveDelay = 0
        vm.loadWorkspaceFolder(tempDir)

        // Flat list should only contain the 3 Markdown files
        let flatNames = Set(vm.flatMarkdownFiles.map(\.name))
        XCTAssertEqual(flatNames, ["README.md", "guide.markdown", "architecture.md"])
        XCTAssertFalse(flatNames.contains("main.swift"))
        XCTAssertFalse(flatNames.contains("config.yaml"))

        // Tree root nodes should only contain "docs" directory, "README.md", and "guide.markdown"
        // (no "main.swift", no "config.yaml", and no "Sources" directory since it has no Markdown files)
        let rootNames = Set(vm.rootFileNodes.map(\.name))
        XCTAssertEqual(rootNames, ["docs", "README.md", "guide.markdown"])

        if let docsNode = vm.rootFileNodes.first(where: { $0.name == "docs" }) {
            let docsChildrenNames = Set((docsNode.children ?? []).map(\.name))
            XCTAssertEqual(docsChildrenNames, ["architecture.md"])
        } else {
            XCTFail("Expected 'docs' directory node in rootFileNodes")
        }
    }

    @MainActor
    func testWorkspaceFolderAndSessionStatePersistenceAcrossLaunches() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FolioPersistenceTest_\(UUID().uuidString)", isDirectory: true)
        let subfolderDir = tempDir.appendingPathComponent("Subfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolderDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("Alpha.md")
        let fileB = subfolderDir.appendingPathComponent("Beta.md")
        try "# Alpha Heading\nFirst document body.\n\n## Alpha Subheading\nDetails here.".write(to: fileA, atomically: true, encoding: .utf8)
        try "# Beta Heading\nSecond document in subfolder.".write(to: fileB, atomically: true, encoding: .utf8)

        let defaultsSuiteName = "com.folio.tests.persistence.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { testDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        // 1. Launch #1: Configure workspace folder, open file, sidebar state, collapsed folders, theme, and editor modes
        do {
            let vm1 = EditorWorkspaceViewModel(userDefaults: testDefaults)
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
            let vm2 = EditorWorkspaceViewModel(userDefaults: testDefaults)
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
            let vm3 = EditorWorkspaceViewModel(userDefaults: testDefaults)
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
            let vm4 = EditorWorkspaceViewModel(userDefaults: testDefaults)
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
            let vm5 = EditorWorkspaceViewModel(userDefaults: testDefaults)
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
    func testNativeSidebarAndNavigationSplitViewHosting() {
        let vm = EditorWorkspaceViewModel()
        XCTAssertEqual(SidebarTab.files.systemImage, "folder")
        XCTAssertEqual(SidebarTab.outline.systemImage, "list.bullet.indent")
        XCTAssertEqual(SidebarTab.search.systemImage, "magnifyingglass")
        XCTAssertEqual(vm.fileFilterText, "")
        XCTAssertTrue(vm.showSidebar)

        // Verify SidebarView renders cleanly across all tabs and filter states
        for tab in SidebarTab.allCases {
            vm.activeSidebarTab = tab
            if tab == .files {
                vm.fileFilterText = "README"
            }
            let hosting = NSHostingView(rootView: SidebarView(viewModel: vm))
            hosting.frame = NSRect(x: 0, y: 0, width: 265, height: 640)
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.frame.width, 265)
        }
        vm.fileFilterText = ""
    }

    @MainActor
    func testProfileSidebarResizeAnimationLatency() throws {
        let vm = EditorWorkspaceViewModel()
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
        // At 1000pt width with default 860pt maxColumnWidth, horizontal centering inset is (1000 - 860) / 2 = 70pt
        XCTAssertEqual(tv.textContainerOrigin.x, 70.0, accuracy: 0.5)
    }
}
