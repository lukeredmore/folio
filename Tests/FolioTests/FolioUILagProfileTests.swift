import AppKit
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class FolioUILagProfileTests: XCTestCase {

    private func findSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let found = findSubview(of: type, in: child) {
                return found
            }
        }
        return nil
    }

    @MainActor
    func testNativeSidebarAndBottomBarHeightAlignment() throws {
        let vm = makeIsolatedViewModel()
        vm.showSidebar = true
        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        let statusHosting = NSHostingView(rootView: StatusBarView(viewModel: vm))
        let statusHeight = statusHosting.fittingSize.height

        let tv = try XCTUnwrap(vm.activeTextView)
        let scrollView = try XCTUnwrap(tv.enclosingScrollView)
        let scrollWindowRect = scrollView.convert(scrollView.bounds, to: nil)
        let editorScrollMinY = scrollWindowRect.minY
        XCTAssertEqual(statusHeight, 30.0, accuracy: 0.5, "StatusBarView height must be 30pt")
        XCTAssertEqual(statusHeight, editorScrollMinY, accuracy: 0.5, "Editor scroll view must end at the StatusBarView top edge")
        XCTAssertEqual(
            scrollWindowRect.maxY, hostingView.bounds.height, accuracy: 1.0, "Editor scroll view canvas must extend all the way to the top edge of the window")
        XCTAssertEqual(scrollView.contentInsets.top, 0.0, accuracy: 0.1, "Editor scroll view must not have automatic top content insets")
        XCTAssertFalse(
            scrollView.subviews.contains(where: { String(describing: type(of: $0)).contains("ScrollPocket") }),
            "Editor scroll view must not contain an opaque NSScrollPocket top bar"
        )
        XCTAssertEqual(tv.visibleRect.minY, 0.0, accuracy: 1.0, "Editor document must start scrolled to the top")

        if let root = window.contentView?.superview {
            if let splitView = findSubview(of: NSSplitView.self, in: root) {
                let titlebarBackgrounds = splitView.subviews.filter {
                    String(describing: type(of: $0)).contains("TitlebarBackgroundView")
                }
                for bg in titlebarBackgrounds {
                    XCTAssertTrue(bg.isHidden, "NSTitlebarBackgroundView must remain hidden so no top bar overlays the editor")
                }
            }
            let searchField = try XCTUnwrap(findSubview(of: NSSearchField.self, in: root))
            _ = searchField
        }

        for tab in SidebarTab.allCases {
            vm.activeSidebarTab = tab
            hostingView.layoutSubtreeIfNeeded()
        }

        if let textView = vm.activeTextView {
            window.makeFirstResponder(textView)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hostingView.layoutSubtreeIfNeeded()
        if let toolbar = window.toolbar,
            let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar" }),
            let v = item.view
        {
            XCTAssertTrue(WindowStatePersistenceAccessor.Coordinator.isDescendantOfToolbarItem(v))
            let wf = v.convert(v.bounds, to: nil)
            let center = NSPoint(x: wf.midX, y: wf.midY)
            if let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0),
                let up = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0.0)
            {
                window.sendEvent(down)
                window.sendEvent(up)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertFalse(vm.showSidebar, "First click on sidebar toolbar button must immediately collapse sidebar")
        if let root = window.contentView?.superview,
            let splitView = findSubview(of: NSSplitView.self, in: root),
            let svc = splitView.delegate as? NSSplitViewController
        {
            XCTAssertNil(splitView.autosaveName, "NSSplitView autosaveName must be cleared to prevent conflicting subview frame restoration")
            XCTAssertTrue(svc.splitViewItems.first?.isCollapsed ?? false, "NSSplitViewItem must be collapsed after first click")
        }

        if let screen = window.screen ?? NSScreen.main {
            XCTAssertFalse(
                WindowStatePersistenceAccessor.Coordinator.isRestorableWindowFrame(screen.frame, for: window),
                "Full-screen rect must not be saved or restored onto a windowed NSWindow"
            )
            XCTAssertTrue(
                WindowStatePersistenceAccessor.Coordinator.isRestorableWindowFrame(
                    NSRect(x: 100, y: 100, width: 960, height: 640),
                    for: window
                )
            )
        }

        // When sidebar closes, bottom status bar auto-hides so editor canvas bleeds full bottom & top
        let closedScrollRect = scrollView.convert(scrollView.bounds, to: nil)
        XCTAssertEqual(closedScrollRect.minY, 0.0, accuracy: 1.0, "Editor scroll view must extend to bottom edge when sidebar is closed")
        XCTAssertEqual(closedScrollRect.maxY, hostingView.bounds.height, accuracy: 1.0, "Editor scroll view must extend to top edge when sidebar is closed")
    }
}
