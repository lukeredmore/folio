import AppKit

/// A rendered diagram opened in the zoom sheet.
public struct ExpandedDiagram: Identifiable {
    public let id = UUID()
    public let source: String
    public let image: NSImage
}

extension HybridMarkdownTextView {

    /// Card rect of a rendered Mermaid block, in view coordinates (matches the card drawing).
    func diagramCardRect(for fullBlockRange: NSRange) -> NSRect? {
        guard let layoutManager = layoutManager, let textContainer = textContainer,
              NSMaxRange(fullBlockRange) <= (string as NSString).length else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: fullBlockRange, actualCharacterRange: nil)
        guard glyphs.location != NSNotFound, glyphs.length > 0 else { return nil }
        let origin = textContainerOrigin
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x = origin.x
        rect.origin.y += origin.y
        rect.size.width = proseColumnWidth > 0 ? proseColumnWidth : bounds.width - origin.x * 2
        return rect.insetBy(dx: 0, dy: 3)
    }

    /// The expand button sits in the card's top-right corner, left of the "MERMAID" badge.
    static func diagramExpandButtonRect(in card: NSRect) -> NSRect {
        NSRect(x: card.maxX - 92, y: card.minY + 4, width: 18, height: 18)
    }

    func drawDiagramExpandButton(in card: NSRect, dimFactor: CGFloat) {
        let button = Self.diagramExpandButtonRect(in: card)
        currentTheme.secondaryTextNSColor.withAlphaComponent(0.10 * dimFactor).setFill()
        NSBezierPath(roundedRect: button, xRadius: 4, yRadius: 4).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand diagram")?
            .withSymbolConfiguration(configuration) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                self.currentTheme.secondaryTextNSColor.withAlphaComponent(0.9 * dimFactor).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let size = tinted.size
            tinted.draw(
                in: NSRect(x: button.midX - size.width / 2, y: button.midY - size.height / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
            )
        }
    }

    /// The rendered Mermaid diagram whose expand button is under `point`, if any.
    func expandableDiagram(at point: NSPoint) -> ExpandedDiagram? {
        guard !isSourceCodeMode else { return nil }
        for decoration in lineDecorations {
            guard case let .mermaidBlockRendered(source, fullBlockRange, _) = decoration.kind,
                  let card = diagramCardRect(for: fullBlockRange),
                  Self.diagramExpandButtonRect(in: card).insetBy(dx: -4, dy: -4).contains(point),
                  let image = DiagramImageRenderer.shared.image(
                      for: DiagramImageRenderer.Key(kind: .mermaid(isDark: currentTheme.isDark), source: source)
                  ) else { continue }
            return ExpandedDiagram(source: source, image: image)
        }
        return nil
    }
}
