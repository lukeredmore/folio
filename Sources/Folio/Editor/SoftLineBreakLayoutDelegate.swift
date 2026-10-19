import AppKit

/// Renders source newlines marked with `MarkdownLiveStyler.softLineBreakAttributeKey` as a
/// space, so a hard-wrapped Markdown paragraph lays out as one wrapping paragraph.
final class SoftLineBreakLayoutDelegate: NSObject, NSLayoutManagerDelegate {
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        isSoftLineBreak(at: charIndex, in: layoutManager) ? .whitespace : action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard isSoftLineBreak(at: charIndex, in: layoutManager),
              let storage = layoutManager.textStorage else {
            return NSRect(origin: glyphPosition, size: .zero)
        }
        let font = (storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont)
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        return NSRect(x: glyphPosition.x, y: 0, width: spaceWidth, height: 0)
    }

    private func isSoftLineBreak(at charIndex: Int, in layoutManager: NSLayoutManager) -> Bool {
        guard let storage = layoutManager.textStorage, charIndex < storage.length else { return false }
        return storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: charIndex, effectiveRange: nil) != nil
    }
}
