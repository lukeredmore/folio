import AppKit
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class SidebarToolbarTests: XCTestCase {
    private func findSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var results: [T] = []
        if let match = root as? T { results.append(match) }
        for child in root.subviews { results.append(contentsOf: findSubviews(of: type, in: child)) }
        return results
    }

    private func makeWindow(_ vm: EditorWorkspaceViewModel) -> NSWindow {
        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unified
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        settle(window)
        return window
    }

    /// Waits for the toolbar to rebuild, which follows the sidebar width a few runloop passes late.
    private func waitForSidebarItemCount(_ expected: Int, in window: NSWindow, timeout: TimeInterval = 3) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var count = visibleSidebarItemCount(in: window)
        while count != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.contentView?.layoutSubtreeIfNeeded()
            count = visibleSidebarItemCount(in: window)
        }
        return count
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func splitView(in window: NSWindow) throws -> NSSplitView {
        try XCTUnwrap(findSubviews(of: NSSplitView.self, in: try XCTUnwrap(window.contentView?.superview)).first)
    }

    /// Sidebar items are the visible toolbar items SwiftUI did not create for the split view itself.
    private func visibleSidebarItemFrames(in window: NSWindow) -> [NSRect] {
        (window.toolbar?.items ?? []).compactMap { item -> NSRect? in
            let id = item.itemIdentifier.rawValue
            guard !id.hasPrefix("com.apple."), !id.hasPrefix("NSToolbar"), item.isVisible,
                let view = item.view, view.bounds.width > 0
            else { return nil }
            return view.convert(view.bounds, to: nil)
        }
        .sorted { $0.minX < $1.minX }
    }

    private func visibleSidebarItemCount(in window: NSWindow) -> Int {
        visibleSidebarItemFrames(in: window).count
    }

    private func toggleSidebarFrame(in window: NSWindow) throws -> NSRect {
        let item = try XCTUnwrap(
            window.toolbar?.items.first { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar" })
        let view = try XCTUnwrap(item.view)
        return view.convert(view.bounds, to: nil)
    }

    private func clippedIndicatorCount(in window: NSWindow) -> Int {
        guard let themeFrame = window.contentView?.superview else { return 0 }
        return findSubviews(of: NSView.self, in: themeFrame).filter {
            String(describing: type(of: $0)).contains("ToolbarClippedItemsIndicator") && !$0.isHidden && $0.frame.width > 0
        }.count
    }

    func testDefaultWidthShowsOptionsMenuAndModePickerOnly() throws {
        let window = makeWindow(makeIsolatedViewModel())
        defer { window.orderOut(nil) }
        XCTAssertEqual(waitForSidebarItemCount(2, in: window), 2)
        XCTAssertEqual(clippedIndicatorCount(in: window), 0)
    }

    func testWideSidebarAddsAddButtonWithoutOverflow() throws {
        let window = makeWindow(makeIsolatedViewModel())
        defer { window.orderOut(nil) }
        let split = try splitView(in: window)

        split.setPosition(SidebarView.addButtonMinimumSidebarWidth, ofDividerAt: 0)
        settle(window)
        XCTAssertEqual(waitForSidebarItemCount(3, in: window), 3)
        XCTAssertEqual(clippedIndicatorCount(in: window), 0, "The add button must fit at its minimum sidebar width")

        // Space-between: the add button hugs the traffic lights, the rest hug the sidebar toggle.
        split.setPosition(400, ofDividerAt: 0)
        settle(window)
        XCTAssertEqual(waitForSidebarItemCount(3, in: window), 3)
        let frames = visibleSidebarItemFrames(in: window)
        let toggle = try toggleSidebarFrame(in: window)
        let zoomButton = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let trafficLightsMaxX = zoomButton.convert(zoomButton.bounds, to: nil).maxX
        XCTAssertLessThan(frames[0].minX - trafficLightsMaxX, 40, "Add button must sit at the leading edge")
        XCTAssertLessThan(toggle.minX - frames[2].maxX, 16, "Mode picker must stay next to the sidebar toggle")
        XCTAssertGreaterThan(frames[1].minX - frames[0].maxX, 40, "A flexible gap must separate the add button from the rest")

        split.setPosition(SidebarView.addButtonMinimumSidebarWidth - 20, ofDividerAt: 0)
        settle(window)
        XCTAssertEqual(waitForSidebarItemCount(2, in: window), 2)
    }

    func testCollapsedSidebarShowsOnlyTheToggle() throws {
        let vm = makeIsolatedViewModel()
        let window = makeWindow(vm)
        defer { window.orderOut(nil) }
        vm.showSidebar = false
        settle(window)
        XCTAssertEqual(waitForSidebarItemCount(0, in: window), 0)
        XCTAssertEqual(clippedIndicatorCount(in: window), 0)
    }
}
