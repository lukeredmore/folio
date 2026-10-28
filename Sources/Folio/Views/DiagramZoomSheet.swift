import AppKit
import SwiftUI

/// Sheet that shows a rendered Mermaid diagram at full size, with pan and zoom.
struct DiagramZoomSheet: View {
    let diagram: ExpandedDiagram
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = DiagramZoomController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Mermaid Diagram")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    controller.zoom(by: 1 / 1.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: [.command])
                .help("Zoom Out")
                Text("\(Int(round(controller.magnification * 100)))%")
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 48)
                Button {
                    controller.zoom(by: 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: [.command])
                .help("Zoom In")
                Button("Fit") { controller.fit() }
                    .keyboardShortcut("0", modifiers: [.command])
                Button("100%") { controller.setMagnification(1) }
                Divider().frame(height: 16)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            DiagramZoomView(image: diagram.image, controller: controller)
        }
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 640, idealHeight: 820)
    }
}

/// Owns the scroll view so toolbar buttons and pinch gestures share one magnification.
@MainActor
final class DiagramZoomController: ObservableObject {
    @Published private(set) var magnification: CGFloat = 1
    weak var scrollView: NSScrollView?

    func zoom(by factor: CGFloat) {
        setMagnification((scrollView?.magnification ?? magnification) * factor)
    }

    func setMagnification(_ value: CGFloat) {
        guard let scrollView = scrollView else { return }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.setMagnification(clamped, centeredAt: center)
        magnification = scrollView.magnification
    }

    func fit() {
        guard let scrollView = scrollView, let document = scrollView.documentView else { return }
        let visible = scrollView.contentSize
        let size = document.bounds.size
        guard size.width > 0, size.height > 0, visible.width > 0, visible.height > 0 else { return }
        setMagnification(min(visible.width / size.width, visible.height / size.height) * 0.95)
    }

    func syncFromScrollView() {
        if let scrollView = scrollView { magnification = scrollView.magnification }
    }
}

struct DiagramZoomView: NSViewRepresentable {
    let image: NSImage
    let controller: DiagramZoomController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let canvas = DiagramCanvasView(image: image)
        scrollView.documentView = canvas
        controller.scrollView = scrollView
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView,
            queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.syncFromScrollView() }
        }
        DispatchQueue.main.async { controller.fit() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    final class Coordinator {
        var observer: NSObjectProtocol?
    }
}

/// Draws the diagram image at its natural size. Drawing happens at the scroll view's
/// magnification, so the vector diagram stays sharp at every zoom level. Dragging pans.
final class DiagramCanvasView: NSView {
    private let image: NSImage
    private var dragStart: NSPoint?
    private var originAtDragStart: NSPoint = .zero

    init(image: NSImage) {
        self.image = image
        let size = NSSize(width: max(image.size.width, 1) + 80, height: max(image.size.height, 1) + 80)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(
            in: NSRect(x: 40, y: 40, width: image.size.width, height: image.size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        originAtDragStart = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView = enclosingScrollView else { return }
        let scale = scrollView.magnification
        let delta = NSPoint(x: (event.locationInWindow.x - start.x) / scale, y: (event.locationInWindow.y - start.y) / scale)
        let target = NSPoint(x: originAtDragStart.x - delta.x, y: originAtDragStart.y + delta.y)
        scrollView.contentView.scroll(to: scrollView.contentView.constrainBoundsRect(NSRect(origin: target, size: scrollView.contentView.bounds.size)).origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        NSCursor.pop()
    }
}

/// Keeps the diagram centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}
