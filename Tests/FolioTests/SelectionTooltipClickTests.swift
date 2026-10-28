import AppKit
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class SelectionTooltipClickTests: XCTestCase {

    private func sendClick(at point: NSPoint, in window: NSWindow) {
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

    func testTooltipButtonsNeverUnderlapTitlebarAndReceiveRealMouseClicks() throws {
        let vm = makeIsolatedViewModel()
        vm.autoSaveEnabled = false
        let doc = """
        # Selection Comments & Inspector Sidebar Demo

        Select any phrase in this document to see the **Liquid Glass selection tooltip** (`Comment`, `Copy`, `Copy Raw`).

        We should migrate the **renderer pipeline** to use `MTLSharedEvent` synchronization across passes so frame pacing stays deterministic under load.

        - [ ] Audit `FolioMediaImageCache` eviction thresholds
        - [x] Verify `Cmd+Ctrl+C` copies all comments with line & column locations
        """
        vm.markdownText = doc
        let rExisting = (doc as NSString).range(of: "**renderer pipeline**")
        vm.addOrUpdateSelectionComment("Double-check whether this stage can run asynchronously.", for: rExisting)
        XCTAssertTrue(vm.isCommentsSidebarVisible)

        let hostingController = NSHostingController(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.toolbarStyle = .unified
        window.contentViewController = hostingController
        window.setContentSize(NSSize(width: 1120, height: 760))
        let hostingView = hostingController.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hostingView.layoutSubtreeIfNeeded()

        let themeFrame = try XCTUnwrap(window.contentView?.superview)
        let tv = try XCTUnwrap(vm.activeTextView)
        let scrollView = try XCTUnwrap(tv.enclosingScrollView)
        window.makeFirstResponder(tv)

        // Verify neither the editor scrollView nor the inspector HostingScrollView creates a 52pt top bar / NSScrollPocket
        XCTAssertEqual(scrollView.contentInsets.top, 0.0, accuracy: 0.5, "Editor NSScrollView must not have a top content inset")
        func collectScrollViews(in view: NSView) -> [NSScrollView] {
            var res: [NSScrollView] = []
            if let sv = view as? NSScrollView { res.append(sv) }
            for sub in view.subviews { res.append(contentsOf: collectScrollViews(in: sub)) }
            return res
        }
        for sv in collectScrollViews(in: themeFrame) where String(describing: type(of: sv)).contains("HostingScrollView") {
            XCTAssertEqual(
                sv.contentInsets.top,
                0.0,
                accuracy: 0.5,
                "Inspector HostingScrollView must ignore top container safe area so AppKit never creates a 52pt white NSScrollPocket bar at the top of the right sidebar"
            )
        }

        // 1. Select text on Line 1 (right below unified toolbar) in .forward direction and verify Comment button is NOT occluded by NSTitlebarView
        let line1Range = (doc as NSString).range(of: "Selection Comments")
        tv.setSelectedRange(line1Range)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        hostingView.layoutSubtreeIfNeeded()

        let line1Anchor = try XCTUnwrap(vm.selectionTooltipAnchor)
        let line1Layout = SelectionActionTooltipView.tooltipPosition(for: line1Anchor, isExpanded: false)
        let line1CommentPt = scrollView.convert(NSPoint(x: line1Layout.centerX, y: line1Layout.centerY - 38.0), to: nil)
        let line1HitView = try XCTUnwrap(themeFrame.hitTest(line1CommentPt))
        XCTAssertFalse(
            String(describing: type(of: line1HitView)).contains("Titlebar"),
            "Top Comment button on Line 1 must never sit beneath NSTitlebarView/NSTitlebarContainerView (hit: \(line1HitView))"
        )

        // 2. Select text on Line 3 ("**Liquid Glass selection tooltip**") and click 'Copy Formatted' & 'Copy Raw' buttons
        let targetRange = (doc as NSString).range(of: "**Liquid Glass selection tooltip**")
        tv.setSelectedRange(targetRange)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        hostingView.layoutSubtreeIfNeeded()

        let anchor = try XCTUnwrap(vm.selectionTooltipAnchor)
        let layout = SelectionActionTooltipView.tooltipPosition(for: anchor, isExpanded: false)

        // Middle button in rail: Copy Formatted (centerY)
        NSPasteboard.general.clearContents()
        let copyFormattedPt = scrollView.convert(NSPoint(x: layout.centerX, y: layout.centerY), to: nil)
        sendClick(at: copyFormattedPt, in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Liquid Glass selection tooltip")

        // Bottom button in rail: Copy Raw (centerY + 38.0)
        NSPasteboard.general.clearContents()
        let copyRawPt = scrollView.convert(NSPoint(x: layout.centerX, y: layout.centerY + 38.0), to: nil)
        sendClick(at: copyRawPt, in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "**Liquid Glass selection tooltip**")

        // 3. Click top button in rail: Add Comment (centerY - 38.0)
        let commentBtnPt = scrollView.convert(NSPoint(x: layout.centerX, y: layout.centerY - 38.0), to: nil)
        let commentHitView = try XCTUnwrap(themeFrame.hitTest(commentBtnPt))
        XCTAssertFalse(
            String(describing: type(of: commentHitView)).contains("Titlebar"),
            "Comment button on Line 3 must not be intercepted by NSTitlebarView (hit: \(commentHitView))"
        )
        sendClick(at: commentBtnPt, in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            vm.activeCommentDraftRange,
            targetRange,
            "Clicking the Comment button in SelectionActionTooltipView must open the comment draft composer"
        )

        // 4. Type into the focused comment TextField via AppKit firstResponder and click the Add button
        let expandedAnchor = try XCTUnwrap(vm.selectionTooltipAnchor)
        let expandedLayout = SelectionActionTooltipView.tooltipPosition(for: expandedAnchor, isExpanded: true)
        if let responder = window.firstResponder as? NSTextView {
            responder.insertText("My new comment from UI click", replacementRange: responder.selectedRange())
        } else {
            XCTFail("Expected comment TextField field editor to be firstResponder, got \(String(describing: window.firstResponder))")
        }
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(vm.activeCommentDraftText, "My new comment from UI click")

        let addBtnPointInScrollView = NSPoint(
            x: expandedLayout.centerX + 160.0 - 7.0 - 22.0 - 6.0 - 21.0,
            y: expandedLayout.centerY
        )
        let addBtnPointInWindow = scrollView.convert(addBtnPointInScrollView, to: nil)
        let addHitView = try XCTUnwrap(themeFrame.hitTest(addBtnPointInWindow))
        XCTAssertFalse(
            String(describing: type(of: addHitView)).contains("Titlebar"),
            "Add button in expanded comment composer must not be intercepted by NSTitlebarView"
        )
        sendClick(at: addBtnPointInWindow, in: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))

        XCTAssertNil(vm.activeCommentDraftRange, "Clicking Add must close the comment composer")
        XCTAssertEqual(vm.selectionComments.count, 2, "Clicking Add must save the new selection comment")
        XCTAssertTrue(vm.selectionComments.contains(where: { $0.commentText == "My new comment from UI click" }))
    }
}
