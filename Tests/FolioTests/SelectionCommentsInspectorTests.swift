import AppKit
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class SelectionCommentsInspectorTests: XCTestCase {

    private func findSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var results: [T] = []
        if let match = root as? T {
            results.append(match)
        }
        for child in root.subviews {
            results.append(contentsOf: findSubviews(of: type, in: child))
        }
        return results
    }

    private func sendClick(at point: NSPoint, in window: NSWindow) {
        if let themeFrame = window.contentView?.superview,
           let hit = themeFrame.hitTest(point),
           String(describing: type(of: hit)).contains("ClippedItemsIndicator") {
            XCTFail("Refusing to click NSToolbarClippedItemsIndicator at \(point) which would open a modal NSMenu")
            return
        }
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        ),
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0.0
        ) else {
            XCTFail("Failed to construct mouse events")
            return
        }
        NSApplication.shared.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let pendingUp = NSApplication.shared.nextEvent(
            matching: .leftMouseUp,
            until: nil,
            inMode: .default,
            dequeue: true
        ) {
            window.sendEvent(pendingUp)
        }
    }

    func testInspectorSidebarButtonsHitTestAndClickActions() throws {
        let suiteName = "com.folio.tests.comments.inspector.\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.autoSaveEnabled = false
        let doc = """
        # Architecture Review

        We should migrate the **renderer pipeline** to use `MTLSharedEvent` synchronization.

        - [ ] Audit `FolioMediaImageCache` eviction thresholds
        """
        vm.markdownText = doc
        let nsDoc = doc as NSString
        let r1 = nsDoc.range(of: "`MTLSharedEvent` synchronization")
        let r2 = nsDoc.range(of: "Audit `FolioMediaImageCache` eviction thresholds")
        vm.addOrUpdateSelectionComment("Verify event signaling overhead.", for: r1)
        vm.addOrUpdateSelectionComment("Cap cache at 128 MB.", for: r2)

        XCTAssertTrue(vm.isCommentsSidebarVisible)
        XCTAssertEqual(vm.selectionComments.count, 2)

        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.toolbarStyle = .unified
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hostingView.layoutSubtreeIfNeeded()

        guard let themeFrame = window.contentView?.superview else {
            XCTFail("Expected window theme frame")
            return
        }

        // Verify zero NSToolbarClippedItemsIndicator overflow on the right side
        let clippedIndicators = findSubviews(of: NSView.self, in: themeFrame).filter {
            String(describing: type(of: $0)).contains("ToolbarClippedItemsIndicator") && !$0.isHidden && $0.frame.width > 0
        }
        XCTAssertTrue(
            clippedIndicators.isEmpty,
            "Left sidebar mode switcher must stay inside the left sidebar titlebar without overflowing into a >> indicator on the right"
        )
        guard clippedIndicators.isEmpty else { return }

        // Verify left sidebar segmented control is positioned inside the left sidebar column (< 265pt)
        let segmentedControls = findSubviews(of: NSSegmentedControl.self, in: themeFrame)
        XCTAssertFalse(segmentedControls.isEmpty, "Expected sidebar mode segmented control in left sidebar titlebar")
        if let modePicker = segmentedControls.first {
            let modeRect = modePicker.convert(modePicker.bounds, to: nil)
            XCTAssertLessThan(modeRect.maxX, 265.0, "Sidebar mode picker must stay on the left side")
        }

        // Verify right-side Liquid Glass titlebar buttons (Hide Comments, Copy All Comments, Delete All Comments)
        let allButtons = findSubviews(of: NSButton.self, in: themeFrame)
        let hideView = try XCTUnwrap(allButtons.first(where: { $0.accessibilityLabel() == "Hide Comments" && !$0.isHidden }))
        let copyView = try XCTUnwrap(allButtons.first(where: { $0.accessibilityLabel() == "Copy All Comments" && !$0.isHidden }))
        let deleteAllView = try XCTUnwrap(allButtons.first(where: { $0.accessibilityLabel() == "Delete All Comments" && !$0.isHidden }))
        XCTAssertNil(allButtons.first(where: { $0.accessibilityLabel() == "Show Comments" && !$0.isHidden }))

        let hideRect = hideView.convert(hideView.bounds, to: nil)
        let copyRect = copyView.convert(copyView.bounds, to: nil)
        let deleteAllRect = deleteAllView.convert(deleteAllView.bounds, to: nil)

        XCTAssertGreaterThan(hideRect.minX, window.frame.width - 220, "Hide Comments toolbar button must be on the top-right")
        XCTAssertGreaterThan(copyRect.minX, hideRect.minX)
        XCTAssertGreaterThan(deleteAllRect.minX, copyRect.minX)

        // 1. Click 'Copy All Comments' liquid glass toolbar button
        NSPasteboard.general.clearContents()
        sendClick(at: NSPoint(x: copyRect.midX, y: copyRect.midY), in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let copiedAll = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copiedAll.contains("Verify event signaling overhead."), "Clicking Copy All toolbar button must copy comments to pasteboard")

        // 2. Verify row buttons inside the inspector sidebar list (Edit & Delete per comment)
        let rowButtons = findSubviews(of: NSButton.self, in: themeFrame).filter { btn in
            let winRect = btn.convert(btn.bounds, to: nil)
            return winRect.minX > window.frame.width - 320 && winRect.minY > 200 && winRect.maxY < window.frame.height - 52
        }.sorted { a, b in
            let ra = a.convert(a.bounds, to: nil)
            let rb = b.convert(b.bounds, to: nil)
            if abs(ra.midY - rb.midY) > 5 {
                return ra.midY > rb.midY
            }
            return ra.midX < rb.midX
        }
        XCTAssertEqual(rowButtons.count, 4, "Expected 4 row buttons (Edit & Delete for each of the 2 comments)")
        guard rowButtons.count == 4 else { return }

        for (i, btn) in rowButtons.enumerated() {
            let winRect = btn.convert(btn.bounds, to: nil)
            let hit = themeFrame.hitTest(NSPoint(x: winRect.midX, y: winRect.midY))
            XCTAssertTrue(hit?.isDescendant(of: btn) ?? false, "Inspector row button \(i) must be hit-testable")
        }

        // Click 'Edit' on first comment row
        let editRect = rowButtons[0].convert(rowButtons[0].bounds, to: nil)
        sendClick(at: NSPoint(x: editRect.midX, y: editRect.midY), in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(vm.activeCommentDraftRange, r1, "Clicking Edit button on first comment must open draft editor")

        vm.cancelCommentDraft()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // Click 'Delete' on first comment row
        let deleteRowRect = rowButtons[1].convert(rowButtons[1].bounds, to: nil)
        sendClick(at: NSPoint(x: deleteRowRect.midX, y: deleteRowRect.midY), in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(vm.selectionComments.count, 1, "Clicking Delete button on first comment row must remove that comment")

        // 3. Click 'Hide Comments' liquid glass toolbar button
        themeFrame.layoutSubtreeIfNeeded()
        let updatedHideRect = hideView.convert(hideView.bounds, to: nil)
        sendClick(at: NSPoint(x: updatedHideRect.midX, y: updatedHideRect.midY), in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hostingView.layoutSubtreeIfNeeded()
        themeFrame.layoutSubtreeIfNeeded()
        XCTAssertFalse(vm.showCommentsSidebar, "Clicking Hide Comments toolbar button must collapse the comments inspector")

        // 4. When closed, verify only the 'Show Comments' bubble button appears in top-right toolbar
        let closedButtons = findSubviews(of: NSButton.self, in: themeFrame)
        let showView = try XCTUnwrap(
            closedButtons.first(where: { $0.accessibilityLabel() == "Show Comments" && !$0.isHidden }),
            "When comments sidebar is closed, top-right toolbar must show single Show Comments bubble button"
        )
        XCTAssertNil(closedButtons.first(where: { $0.accessibilityLabel() == "Copy All Comments" && !$0.isHidden }))
        XCTAssertNil(closedButtons.first(where: { $0.accessibilityLabel() == "Delete All Comments" && !$0.isHidden }))

        let showRect = showView.convert(showView.bounds, to: nil)
        XCTAssertGreaterThan(showRect.minX, window.frame.width - 120, "Show Comments bubble button must be in the top-right")
        sendClick(at: NSPoint(x: showRect.midX, y: showRect.midY), in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hostingView.layoutSubtreeIfNeeded()
        themeFrame.layoutSubtreeIfNeeded()
        XCTAssertTrue(vm.showCommentsSidebar, "Clicking Show Comments bubble button must re-open the comments inspector")
    }

    func testScrollAndCursorMovementDoNotBroadcastRedundantViewModelChanges() throws {
        let suiteName = "com.folio.tests.comments.lag.\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.autoSaveEnabled = false
        let paragraph = "We should migrate the **renderer pipeline** to use `MTLSharedEvent` synchronization across passes.\n\n"
        let doc = "# Performance Audit\n\n" + String(repeating: paragraph, count: 30)
        vm.markdownText = doc
        let r1 = (doc as NSString).range(of: "`MTLSharedEvent` synchronization")
        vm.addOrUpdateSelectionComment("Verify signaling latency.", for: r1)

        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let tv = try XCTUnwrap(vm.activeTextView)
        let scrollView = try XCTUnwrap(tv.enclosingScrollView)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        vm.updateSelectionStats(selectedRange: NSRange(location: 0, length: 0))

        var changeCount = 0
        let cancellable = vm.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        // 120 scroll frame notifications with zero selection must emit 0 @Published broadcasts
        for frame in 1...120 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(frame * 2)))
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
        XCTAssertEqual(
            changeCount,
            0,
            "Scrolling without an active selection tooltip must emit 0 objectWillChange notifications on EditorWorkspaceViewModel"
        )

        // Moving the cursor without selecting text must emit 0 @Published broadcasts
        for loc in 1...40 {
            vm.updateSelectionStats(selectedRange: NSRange(location: loc, length: 0))
        }
        XCTAssertEqual(
            changeCount,
            0,
            "Moving the insertion point without a text selection must emit 0 objectWillChange notifications"
        )
    }

    func testOpeningFileInSystemTmpDoesNotScanOrWatchTmpRoot() throws {
        let suiteName = "com.folio.tests.comments.tmpguard.\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(EditorWorkspaceViewModel.isSystemTemporaryRootDirectory(URL(fileURLWithPath: "/tmp")))
        XCTAssertTrue(EditorWorkspaceViewModel.isSystemTemporaryRootDirectory(URL(fileURLWithPath: "/private/tmp")))

        let tmpFile = URL(fileURLWithPath: "/tmp/folio_tmp_guard_\(UUID().uuidString).md")
        try "# Temp Doc\n\nHello world.\n".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        vm.workspaceFolderURL = nil
        vm.openPathFromCLI(tmpFile.path)

        XCTAssertEqual(vm.currentFileURL?.standardizedFileURL, tmpFile.standardizedFileURL)
        XCTAssertNil(vm.workspaceFolderURL, "Opening a file directly in /tmp must not promote /tmp to the workspace folder")
        XCTAssertEqual(vm.parentDirWatchDescriptor, -1, "Must not attach a parent directory DispatchSource watcher to /tmp")
    }
}
