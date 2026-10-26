import AppKit
import SwiftUI

final class PassThroughAccessorNSView: NSView {
    var onMoveToWindow: ((NSWindow) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window { onMoveToWindow?(window) }
    }
}

struct WindowStatePersistenceAccessor: NSViewRepresentable {
    let userDefaults: UserDefaults
    static let windowFrameDefaultsKey = "Folio.MainWindowFrame.v1"

    func makeCoordinator() -> Coordinator {
        Coordinator(userDefaults: userDefaults)
    }

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        let coordinator = context.coordinator
        view.onMoveToWindow = { [weak coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {
        guard let window = nsView.window else { return }
        if context.coordinator.attachedWindow !== window {
            context.coordinator.attach(to: window)
        } else {
            context.coordinator.configureWindowAppearance(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        let userDefaults: UserDefaults
        weak var attachedWindow: NSWindow?
        nonisolated(unsafe) var mouseMonitor: Any?
        weak var forwardedToolbarMouseWindow: NSWindow?

        init(userDefaults: UserDefaults) {
            self.userDefaults = userDefaults
        }

        deinit {
            if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
            NotificationCenter.default.removeObserver(self)
        }

        func configureWindowAppearance(_ window: NSWindow) {
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            suppressSplitViewTitlebarPocketBackgrounds(in: window.contentView?.superview)
        }

        func suppressSplitViewTitlebarPocketBackgrounds(in root: NSView?) {
            guard let root else { return }
            let typeName = String(describing: type(of: root))
            if typeName.contains("NSTitlebarBackgroundView") {
                if !root.isHidden {
                    root.isHidden = true
                }
                root.alphaValue = 0
            }
            if let split = root as? NSSplitView,
               let svc = split.delegate as? NSSplitViewController {
                for item in svc.splitViewItems {
                    if !item.allowsFullHeightLayout {
                        item.allowsFullHeightLayout = true
                    }
                    if item.titlebarSeparatorStyle != .none {
                        item.titlebarSeparatorStyle = .none
                    }
                }
            }
            for subview in root.subviews {
                suppressSplitViewTitlebarPocketBackgrounds(in: subview)
            }
        }

        static func isRestorableWindowFrame(_ rect: NSRect, for window: NSWindow) -> Bool {
            guard rect.width >= 720, rect.height >= 480 else { return false }
            if let screen = window.screen ?? NSScreen.main,
               rect.width >= screen.frame.width && rect.height >= screen.visibleFrame.height { return false }
            return true
        }

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            let nc = NotificationCenter.default
            if let oldWindow = attachedWindow {
                for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                             NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    nc.removeObserver(self, name: name, object: oldWindow)
                }
            }
            attachedWindow = window
            configureWindowAppearance(window)
            installFullScreenToolbarMouseMonitorIfNeeded()
            if !window.styleMask.contains(.fullScreen),
               let savedFrameString = userDefaults.string(forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey) {
                let rect = NSRectFromString(savedFrameString)
                if Self.isRestorableWindowFrame(rect, for: window) {
                    window.setFrame(rect, display: true)
                } else {
                    userDefaults.removeObject(forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey)
                }
            }
            nc.addObserver(self, selector: #selector(windowDidChangeFrame(_:)), name: NSWindow.didResizeNotification, object: window)
            nc.addObserver(self, selector: #selector(windowDidChangeFrame(_:)), name: NSWindow.didMoveNotification, object: window)
            nc.addObserver(self, selector: #selector(windowDidTransitionFullScreen(_:)), name: NSWindow.didEnterFullScreenNotification, object: window)
            nc.addObserver(self, selector: #selector(windowDidTransitionFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.suppressSplitViewTitlebarPocketBackgrounds(in: window.contentView?.superview)
                guard let splitView = Self.findSplitView(in: window.contentView?.superview),
                      splitView.autosaveName != nil else { return }
                splitView.autosaveName = nil
            }
        }

        private func installFullScreenToolbarMouseMonitorIfNeeded() {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handleFullScreenToolbarMouseEvent(event) ?? event
            }
        }

        func handleFullScreenToolbarMouseEvent(_ event: NSEvent) -> NSEvent? {
            guard let mainWindow = attachedWindow, mainWindow.styleMask.contains(.fullScreen) else {
                forwardedToolbarMouseWindow = nil
                return event
            }
            guard event.window === mainWindow else {
                if event.type == .leftMouseUp { forwardedToolbarMouseWindow = nil }
                return event
            }
            let screenPt = mainWindow.convertPoint(toScreen: event.locationInWindow)
            if event.type == .leftMouseDown {
                forwardedToolbarMouseWindow = nil
                guard let childWindows = mainWindow.childWindows else { return event }
                for child in childWindows where String(describing: type(of: child)).contains("ToolbarFullScreenWindow") {
                    let ptInChild = child.convertPoint(fromScreen: screenPt)
                    if let childHit = child.contentView?.superview?.hitTest(ptInChild),
                       Self.isDescendantOfToolbarItem(childHit),
                       Self.forwardMouseEvent(event, to: child, locationInTarget: ptInChild) {
                        forwardedToolbarMouseWindow = child
                        return nil
                    }
                }
            } else if let child = forwardedToolbarMouseWindow {
                let ptInChild = child.convertPoint(fromScreen: screenPt)
                if event.type == .leftMouseUp { forwardedToolbarMouseWindow = nil }
                if Self.forwardMouseEvent(event, to: child, locationInTarget: ptInChild) { return nil }
            }
            return event
        }

        static func forwardMouseEvent(_ event: NSEvent, to targetWindow: NSWindow, locationInTarget: NSPoint) -> Bool {
            guard let forwarded = NSEvent.mouseEvent(
                with: event.type, location: locationInTarget, modifierFlags: event.modifierFlags,
                timestamp: event.timestamp, windowNumber: targetWindow.windowNumber, context: nil,
                eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
            ) else { return false }
            targetWindow.sendEvent(forwarded)
            return true
        }

        static func isDescendantOfToolbarItem(_ view: NSView?) -> Bool {
            var current = view
            while let v = current {
                if String(describing: type(of: v)).contains("ToolbarItem") { return true }
                current = v.superview
            }
            return false
        }

        @objc func windowDidTransitionFullScreen(_ notification: Notification) {
            guard let window = attachedWindow else { return }
            configureWindowAppearance(window)
        }

        @objc func windowDidChangeFrame(_ notification: Notification) {
            guard let window = attachedWindow, !window.styleMask.contains(.fullScreen),
                  Self.isRestorableWindowFrame(window.frame, for: window) else { return }
            userDefaults.set(NSStringFromRect(window.frame), forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey)
        }

        static func findSplitView(in root: NSView?) -> NSSplitView? {
            guard let root else { return nil }
            if let split = root as? NSSplitView { return split }
            for subview in root.subviews {
                if let found = findSplitView(in: subview) { return found }
            }
            return nil
        }
    }
}

final class CompactSidebarSegmentedControl: NSSegmentedControl {
    override var intrinsicContentSize: NSSize { NSSize(width: 66, height: 22) }
    override var mouseDownCanMoveWindow: Bool { false }
}

final class SidebarModeTitlebarAnchorView: NSView {
    let segmentedControl = CompactSidebarSegmentedControl(frame: NSRect(x: 0, y: 0, width: 66, height: 22))
    var isSidebarVisible: Bool = true { didSet { syncTitlebarControl() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleLayoutNotification(_:)),
                name: NSWindow.didResizeNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleLayoutNotification(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: nil
            )
            syncTitlebarControl()
            DispatchQueue.main.async { [weak self] in self?.syncTitlebarControl() }
        } else {
            segmentedControl.removeFromSuperview()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleLayoutNotification(_ notification: Notification) { syncTitlebarControl() }
    override func layout() {
        super.layout()
        syncTitlebarControl()
    }

    func syncTitlebarControl() {
        guard let window, let themeFrame = window.contentView?.superview else {
            segmentedControl.removeFromSuperview()
            return
        }
        let hostView = Self.findSubview(named: "NSTitlebarView", in: themeFrame) ?? themeFrame
        if segmentedControl.superview !== hostView {
            hostView.addSubview(segmentedControl, positioned: .above, relativeTo: nil)
        }
        let isCollapsed = Self.isLeadingSidebarCollapsed(in: themeFrame)
        let shouldShow = isSidebarVisible && !isCollapsed
        segmentedControl.isHidden = !shouldShow
        guard shouldShow else { return }

        let controlWidth: CGFloat = 66, controlHeight: CGFloat = 22
        let minAllowedX: CGFloat = {
            if let zoom = window.standardWindowButton(.zoomButton) {
                return hostView.convert(zoom.bounds, from: zoom).maxX + 12.0
            }
            return 90.0
        }()
        if let toggleView = window.toolbar?.items.first(where: {
            $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
        })?.view, toggleView.window === window, toggleView.bounds.width > 0 {
            let toggleRect = hostView.convert(toggleView.bounds, from: toggleView)
            let y = round(toggleRect.midY - controlHeight / 2.0)
            let x: CGFloat = (toggleRect.minX - minAllowedX >= controlWidth + 6.0)
                ? min(toggleRect.minX - controlWidth - 8.0, 255.0 - controlWidth - 8.0)
                : max(minAllowedX, min(toggleRect.maxX + 8.0, 255.0 - controlWidth - 8.0))
            segmentedControl.frame = NSRect(x: round(x), y: y, width: controlWidth, height: controlHeight)
        } else {
            let y = hostView === themeFrame
                ? round(themeFrame.bounds.height - 26.0 - controlHeight / 2.0)
                : round((hostView.bounds.height - controlHeight) / 2.0)
            segmentedControl.frame = NSRect(x: round(max(minAllowedX, 140.0)), y: y, width: controlWidth, height: controlHeight)
        }
    }

    private static func isLeadingSidebarCollapsed(in root: NSView) -> Bool {
        if let split = root as? NSSplitView,
           let svc = split.delegate as? NSSplitViewController,
           let sidebarItem = svc.splitViewItems.first(where: { $0.behavior == .sidebar }) {
            return sidebarItem.isCollapsed
        }
        for child in root.subviews {
            if isLeadingSidebarCollapsed(in: child) { return true }
        }
        return false
    }

    private static func findSubview(named classSubstring: String, in root: NSView) -> NSView? {
        if String(describing: type(of: root)).contains(classSubstring) { return root }
        for child in root.subviews {
            if let match = findSubview(named: classSubstring, in: child) { return match }
        }
        return nil
    }
}

struct SidebarModeSegmentedControl: NSViewRepresentable {
    @Binding var activeTab: SidebarTab
    var isVisible: Bool

    final class Coordinator: NSObject {
        var parent: SidebarModeSegmentedControl
        init(_ parent: SidebarModeSegmentedControl) { self.parent = parent }
        @MainActor @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let tabs = SidebarTab.allCases
            let idx = sender.selectedSegment
            guard idx >= 0, idx < tabs.count, parent.activeTab != tabs[idx] else { return }
            parent.activeTab = tabs[idx]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SidebarModeTitlebarAnchorView {
        let anchor = SidebarModeTitlebarAnchorView(frame: .zero)
        let tabs = SidebarTab.allCases
        let control = anchor.segmentedControl
        control.segmentCount = tabs.count
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChanged(_:))
        for (idx, tab) in tabs.enumerated() {
            let img = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.rawValue)
            control.setImage(img, forSegment: idx)
            control.setImageScaling(.scaleProportionallyDown, forSegment: idx)
            control.setWidth(20, forSegment: idx)
            control.setToolTip(tab.rawValue, forSegment: idx)
        }
        if let selectedIdx = tabs.firstIndex(of: activeTab) { control.selectedSegment = selectedIdx }
        anchor.isSidebarVisible = isVisible
        return anchor
    }

    func updateNSView(_ nsView: SidebarModeTitlebarAnchorView, context: Context) {
        context.coordinator.parent = self
        let tabs = SidebarTab.allCases
        if let selectedIdx = tabs.firstIndex(of: activeTab), nsView.segmentedControl.selectedSegment != selectedIdx {
            nsView.segmentedControl.selectedSegment = selectedIdx
        }
        nsView.isSidebarVisible = isVisible
        nsView.syncTitlebarControl()
    }
}
