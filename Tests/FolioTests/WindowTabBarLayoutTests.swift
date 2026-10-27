import AppKit
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class WindowTabBarLayoutTests: XCTestCase {

    private let sampleDocument = """
    # Folio Code Audit: Findings and Recommendations

    2026-10-27. Read-only audit of `main`, about 48k lines of Rust and Swift.

    ## Summary

    The editor, sidebar, and comments inspector share one window.
    """

    private func assertRegionClearsTitlebar(
        _ hosted: HostedMainWindow,
        identifier: String,
        _ state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSRect {
        let region = try XCTUnwrap(
            hosted.markedRegionFrame(identifier: identifier),
            "\(state): \(identifier) must be on screen",
            file: file, line: line
        )
        let safeTop = hosted.window.contentLayoutRect.maxY
        XCTAssertLessThanOrEqual(
            region.maxY, safeTop + 0.5,
            "\(state): \(identifier) top \(region.maxY) must be at or below contentLayoutRect top \(safeTop)",
            file: file, line: line
        )
        let controls = hosted.titlebarControlFrames()
        XCTAssertFalse(controls.isEmpty, "\(state): expected traffic lights and toolbar items", file: file, line: line)
        for control in controls {
            XCTAssertFalse(
                region.intersects(control.frame),
                "\(state): \(identifier) \(region) overlaps \(control.name) at \(control.frame)",
                file: file, line: line
            )
        }
        return region
    }

    /// The external-update notice rises from the autosave indicator in the 30pt bottom status bar.
    private func assertUpdateTooltipAnchoredToStatusBar(
        _ hosted: HostedMainWindow,
        _ state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let tooltip = try assertRegionClearsTitlebar(
            hosted, identifier: ExternalUpdateTooltipView.layoutRegionIdentifier, state, file: file, line: line
        )
        XCTAssertGreaterThan(tooltip.minY, 10, "\(state): tooltip must sit above the status bar", file: file, line: line)
        XCTAssertLessThan(tooltip.minY, 40, "\(state): tooltip must start at the status bar", file: file, line: line)
    }

    private func assertFirstLineBelowSafeArea(
        _ hosted: HostedMainWindow,
        _ state: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let firstLine = try hosted.firstEditorLineFrame()
        let safeTop = hosted.window.contentLayoutRect.maxY
        XCTAssertGreaterThan(firstLine.height, 1, "\(state): first editor line must be laid out", file: file, line: line)
        XCTAssertLessThanOrEqual(
            firstLine.maxY, safeTop + 0.5,
            "\(state): first editor line top \(firstLine.maxY) is hidden above contentLayoutRect top \(safeTop)",
            file: file, line: line
        )
    }

    func testTabbedWindowKeepsBannersAndFirstLineBelowTabBar() throws {
        for showSidebar in [true, false] {
            let state = showSidebar ? "tabbed, sidebar open" : "tabbed, sidebar closed"
            let hosted = try HostedMainWindow(showSidebar: showSidebar, markdown: sampleDocument)
            defer { hosted.close() }
            let untabbedSafeTop = hosted.window.contentLayoutRect.maxY

            hosted.addSecondTab()
            XCTAssertEqual(hosted.window.tabGroup?.windows.count, 2, "\(state): expected two native tabs")
            XCTAssertTrue(hosted.window.tabGroup?.isTabBarVisible ?? false, "\(state): native tab bar must be visible")
            XCTAssertLessThan(
                hosted.window.contentLayoutRect.maxY, untabbedSafeTop - 1,
                "\(state): the tab bar must lower the top of contentLayoutRect"
            )

            hosted.showExternalUpdateNotice()
            hosted.viewModel.showFindReplaceBar = true
            hosted.pump(0.3)
            hosted.writeSnapshot(named: showSidebar ? "tabbed-sidebar-open" : "tabbed-sidebar-closed")
            try assertUpdateTooltipAnchoredToStatusBar(hosted, state)
            _ = try assertRegionClearsTitlebar(hosted, identifier: DocumentBannerStack.layoutRegionIdentifier, state)
            try assertFirstLineBelowSafeArea(hosted, state)
        }
    }

    func testUntabbedWindowKeepsBannersBelowToolbarAndCanvasFullBleed() throws {
        for showSidebar in [true, false] {
            let state = showSidebar ? "untabbed, sidebar open" : "untabbed, sidebar closed"
            let hosted = try HostedMainWindow(showSidebar: showSidebar, markdown: sampleDocument)
            defer { hosted.close() }
            XCTAssertFalse(hosted.window.tabGroup?.isTabBarVisible ?? false, "\(state): no tab bar expected")

            hosted.showExternalUpdateNotice()
            hosted.viewModel.showFindReplaceBar = true
            hosted.pump(0.3)
            hosted.writeSnapshot(named: showSidebar ? "untabbed-sidebar-open" : "untabbed-sidebar-closed")
            try assertUpdateTooltipAnchoredToStatusBar(hosted, state)
            _ = try assertRegionClearsTitlebar(hosted, identifier: DocumentBannerStack.layoutRegionIdentifier, state)

            let scrollView = try XCTUnwrap(hosted.viewModel.activeTextView?.enclosingScrollView)
            let scrollRect = scrollView.convert(scrollView.bounds, to: nil)
            XCTAssertEqual(
                scrollRect.maxY, hosted.hostingView.bounds.height, accuracy: 1.0,
                "\(state): editor canvas must still bleed behind the transparent toolbar"
            )
        }
    }

    func testUpdateTooltipTakesClicksWithoutBlockingEditor() throws {
        let hosted = try HostedMainWindow(showSidebar: true, markdown: sampleDocument)
        defer { hosted.close() }
        hosted.showExternalUpdateNotice()
        let textView = try XCTUnwrap(hosted.viewModel.activeTextView)
        let firstLine = try hosted.firstEditorLineFrame()
        let editorHit = hosted.window.contentView?.superview?.hitTest(NSPoint(x: firstLine.midX, y: firstLine.midY))
        XCTAssertTrue(editorHit === textView, "The tooltip overlay must not block clicks on the editor text")

        let tooltip = try XCTUnwrap(hosted.markedRegionFrame(identifier: ExternalUpdateTooltipView.layoutRegionIdentifier))
        let dismissPoint = NSPoint(x: tooltip.maxX - 18, y: tooltip.maxY - 16)
        hosted.click(at: dismissPoint)
        hosted.pump(0.2)
        XCTAssertNil(hosted.viewModel.externalUpdateNotice, "Clicking the tooltip close button must dismiss the notice")
        XCTAssertNil(hosted.markedRegionFrame(identifier: ExternalUpdateTooltipView.layoutRegionIdentifier))
    }

    func testCommentsPillStaysInToolbarRowWithTabBar() throws {
        let hosted = try HostedMainWindow(showSidebar: false, markdown: sampleDocument)
        defer { hosted.close() }
        let range = (sampleDocument as NSString).range(of: "48k lines")
        hosted.viewModel.addOrUpdateSelectionComment("Count again.", for: range)
        hosted.addSecondTab()
        hosted.showExternalUpdateNotice()
        hosted.writeSnapshot(named: "tabbed-comments-inspector")

        let themeFrame = try XCTUnwrap(hosted.window.contentView?.superview)
        let hideButton = try XCTUnwrap(
            Self.findButton(labeled: "Hide Comments", in: themeFrame),
            "Comments inspector pill must be visible"
        )
        let close = try XCTUnwrap(hosted.window.standardWindowButton(.closeButton))
        let pillRect = hideButton.convert(hideButton.bounds, to: nil)
        let closeRect = close.convert(close.bounds, to: nil)
        XCTAssertEqual(pillRect.midY, closeRect.midY, accuracy: 2.0, "Comments pill must align with the traffic lights")
        XCTAssertGreaterThan(
            pillRect.minY, hosted.window.contentLayoutRect.maxY,
            "Comments pill must stay above the tab bar"
        )
    }

    private static func findButton(labeled label: String, in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.accessibilityLabel() == label, !button.isHiddenOrHasHiddenAncestor {
            return button
        }
        for child in root.subviews {
            if let match = findButton(labeled: label, in: child) { return match }
        }
        return nil
    }

    func testRemovingSecondTabRestoresFullBleedCanvas() throws {
        let hosted = try HostedMainWindow(showSidebar: true, markdown: sampleDocument)
        defer { hosted.close() }
        hosted.addSecondTab()
        let scrollView = try XCTUnwrap(hosted.viewModel.activeTextView?.enclosingScrollView)
        let tabbedRect = scrollView.convert(scrollView.bounds, to: nil)
        XCTAssertLessThanOrEqual(
            tabbedRect.maxY, hosted.window.contentLayoutRect.maxY + 0.5,
            "Editor canvas must stop at the tab bar while two tabs are open"
        )

        hosted.tabWindow?.close()
        hosted.pump(0.4)
        XCTAssertFalse(hosted.window.tabGroup?.isTabBarVisible ?? false, "Tab bar must hide after the second tab closes")
        let untabbedRect = scrollView.convert(scrollView.bounds, to: nil)
        XCTAssertEqual(
            untabbedRect.maxY, hosted.hostingView.bounds.height, accuracy: 1.0,
            "Editor canvas must return to the top edge of the window once the tab bar is gone"
        )
    }
}
