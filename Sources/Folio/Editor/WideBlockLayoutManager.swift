import AppKit

/// Layout manager that leaves the glyphs of wide table rows (WideBlockTextContainer regions) out
/// of NSTextView's normal text drawing, which clips to the column. HybridMarkdownTextView draws
/// those rows itself, unclipped, through `drawWideRegionGlyphs`.
final class WideBlockLayoutManager: NSLayoutManager {

    private var isDrawingWideRegions = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !isDrawingWideRegions,
            let container = textContainers.first as? WideBlockTextContainer,
            !container.regions.isEmpty
        else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for region in container.regions {
            let wide = glyphRange(forCharacterRange: region.range, actualCharacterRange: nil)
            guard NSMaxRange(wide) > cursor else { continue }
            guard wide.location < end else { break }
            if wide.location > cursor {
                super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: wide.location - cursor), at: origin)
            }
            cursor = max(cursor, NSMaxRange(wide))
        }
        if cursor < end {
            super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: end - cursor), at: origin)
        }
    }

    /// Draws the wide-region line fragments that intersect `rect` (view coordinates).
    func drawWideRegionGlyphs(intersecting rect: NSRect, at origin: NSPoint) {
        guard let container = textContainers.first as? WideBlockTextContainer else { return }
        isDrawingWideRegions = true
        defer { isDrawingWideRegions = false }
        for region in container.regions {
            let wide = glyphRange(forCharacterRange: region.range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: wide) { fragment, _, _, lineGlyphs, _ in
                guard fragment.offsetBy(dx: origin.x, dy: origin.y).intersects(rect) else { return }
                self.drawGlyphs(forGlyphRange: lineGlyphs, at: origin)
            }
        }
    }

    static func shouldSuppressSpellCheck(in storage: NSTextStorage, range: NSRange) -> Bool {
        let clampedLoc = max(0, min(range.location, storage.length))
        let clampedLen = max(0, min(range.length, storage.length - clampedLoc))
        guard clampedLen > 0 else { return false }
        let safeRange = NSRange(location: clampedLoc, length: clampedLen)
        var suppress = false
        storage.enumerateAttributes(in: safeRange, options: []) { attrs, _, stop in
            if attrs[MarkdownLiveStyler.noSpellCheckAttributeKey] != nil || attrs[MarkdownLiveStyler.collapsedTokenAttributeKey] != nil
                || attrs[MarkdownLiveStyler.inlineCodeFontAttributeKey] != nil || attrs[MarkdownLiveStyler.inlineMathSpanAttributeKey] != nil
            {
                suppress = true
                stop.pointee = true
            }
        }
        return suppress
    }

    override func addTemporaryAttribute(_ attrName: NSAttributedString.Key, value: Any, forCharacterRange charRange: NSRange) {
        if attrName == .spellingState,
            let storage = textStorage,
            Self.shouldSuppressSpellCheck(in: storage, range: charRange)
        {
            return
        }
        super.addTemporaryAttribute(attrName, value: value, forCharacterRange: charRange)
    }

    override func addTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any] = [:], forCharacterRange charRange: NSRange) {
        if attrs[.spellingState] != nil,
            let storage = textStorage,
            Self.shouldSuppressSpellCheck(in: storage, range: charRange)
        {
            var filtered = attrs
            filtered.removeValue(forKey: .spellingState)
            guard !filtered.isEmpty else { return }
            super.addTemporaryAttributes(filtered, forCharacterRange: charRange)
            return
        }
        super.addTemporaryAttributes(attrs, forCharacterRange: charRange)
    }

    override func setTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any], forCharacterRange charRange: NSRange) {
        if attrs[.spellingState] != nil,
            let storage = textStorage,
            Self.shouldSuppressSpellCheck(in: storage, range: charRange)
        {
            var filtered = attrs
            filtered.removeValue(forKey: .spellingState)
            super.setTemporaryAttributes(filtered, forCharacterRange: charRange)
            return
        }
        super.setTemporaryAttributes(attrs, forCharacterRange: charRange)
    }
}
