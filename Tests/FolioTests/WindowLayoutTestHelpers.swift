import AppKit
import SwiftUI
import XCTest
@testable import Folio

/// A real `NSWindow` that hosts `MainWindowView`, with an optional second native window tab.
@MainActor
final class HostedMainWindow {
    let viewModel: EditorWorkspaceViewModel
    let window: NSWindow
    let hostingView: NSHostingView<MainWindowView>
    private(set) var tabWindow: NSWindow?

    /// `viewModel` must come from `XCTestCase.makeIsolatedViewModel()`.
    init(viewModel: EditorWorkspaceViewModel, showSidebar: Bool, markdown: String) {
        self.viewModel = viewModel
        viewModel.autoSaveEnabled = false
        viewModel.showSidebar = showSidebar
        viewModel.markdownText = markdown
        hostingView = NSHostingView(rootView: MainWindowView(viewModel: viewModel))
        window = Self.makeWindow()
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        pump(0.2)
    }

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "FolioTabBarLayoutTests"
        return window
    }

    /// Tabs a second window into this one so the native tab bar appears, then reselects this tab.
    func addSecondTab() {
        let second = Self.makeWindow()
        second.contentView = NSHostingView(rootView: Text("Second tab"))
        window.addTabbedWindow(second, ordered: .above)
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        tabWindow = second
        pump(0.4)
    }

    func showExternalUpdateNotice() {
        viewModel.externalUpdateNotice = ExternalUpdateNotice(
            fileURL: URL(fileURLWithPath: "/tmp/folio-audit.md"),
            previousText: "old",
            updatedText: "new",
            addedLinesCount: 20,
            removedLinesCount: 1,
            changedLineNumbers: [3],
            changedCharacterRanges: [],
            diffHunks: []
        )
        pump(0.3)
    }

    func pump(_ seconds: TimeInterval) {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        hostingView.layoutSubtreeIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    func close() {
        tabWindow?.orderOut(nil)
        window.orderOut(nil)
    }

    /// Window-coordinate frame of the `LayoutRegionMarker` view with `identifier`, if it is on screen.
    func markedRegionFrame(identifier: String) -> NSRect? {
        guard let root = window.contentView?.superview,
              let marker = Self.findView(identifier: identifier, in: root),
              !marker.isHiddenOrHasHiddenAncestor else { return nil }
        let frame = marker.convert(marker.bounds, to: nil)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private static func findView(identifier: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == identifier { return root }
        for child in root.subviews {
            if let match = findView(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    /// Window-coordinate frames of the traffic lights and every visible toolbar item in this window.
    func titlebarControlFrames() -> [(name: String, frame: NSRect)] {
        var frames: [(String, NSRect)] = []
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            if let button = window.standardWindowButton(type), !button.isHidden {
                frames.append(("window button \(type.rawValue)", button.convert(button.bounds, to: nil)))
            }
        }
        for item in window.toolbar?.items ?? [] {
            guard let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.width > 0, view.bounds.height > 0 else { continue }
            frames.append((item.itemIdentifier.rawValue, view.convert(view.bounds, to: nil)))
        }
        return frames
    }

    /// Window-coordinate frame of the first line of text in the editor.
    func firstEditorLineFrame() throws -> NSRect {
        let textView = try XCTUnwrap(viewModel.activeTextView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        var lineRange = NSRange(location: 0, length: 0)
        _ = layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &lineRange)
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: lineRange, in: container)
        let origin = textView.textContainerOrigin
        let inTextView = glyphBounds.offsetBy(dx: origin.x, dy: origin.y)
        return textView.convert(inTextView, to: nil)
    }

    /// Sends a real left click at `point` (window coordinates) through the window's event path.
    func click(at point: NSPoint) {
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ) else { return }
        NSApplication.shared.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let pendingUp = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: nil, inMode: .default, dequeue: true) {
            window.sendEvent(pendingUp)
        }
    }

    /// Writes a PNG of the whole window (titlebar, tab bar, and content) when an output directory is set.
    func writeSnapshot(named name: String) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["FOLIO_LAYOUT_SNAPSHOT_DIR"] ?? env["TEST_UNDECLARED_OUTPUTS_DIR"],
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        captureOnScreenPixels(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-screen.png"))
    }

    /// Captures the composited on-screen window, which includes glass and tab titles that `cacheDisplay` omits.
    private func captureOnScreenPixels(to url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
