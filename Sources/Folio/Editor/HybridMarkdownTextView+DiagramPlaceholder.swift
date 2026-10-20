import AppKit

extension HybridMarkdownTextView {

    /// Centered status text for a diagram card whose image is not available: still rendering
    /// in the background, or failed to render.
    func drawDiagramPlaceholder(in rect: NSRect, key: DiagramImageRenderer.Key, dimFactor: CGFloat) {
        let message = DiagramImageRenderer.shared.isPending(key) ? "Rendering diagram…" : "Diagram could not be rendered"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: currentTheme.secondaryTextNSColor.withAlphaComponent(0.8 * dimFactor)
        ]
        let text = message as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }
}
