import AppKit

/// Renders source newlines marked with `MarkdownLiveStyler.softLineBreakAttributeKey` as a
/// space, keeps inactive `$...$` inline math spans atomic across line wraps, and expands
/// line fragment heights to accommodate tall inline equations.
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

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldBreakLineByWordBeforeCharacterAt charIndex: Int
    ) -> Bool {
        shouldAllowBreak(beforeCharacterAt: charIndex, in: layoutManager)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldBreakLineByHyphenatingBeforeCharacterAt charIndex: Int
    ) -> Bool {
        shouldAllowBreak(beforeCharacterAt: charIndex, in: layoutManager)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return false }
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let clampedLoc = max(0, min(charRange.location, storage.length))
        let clampedLen = max(0, min(charRange.length, storage.length - clampedLoc))
        guard clampedLen > 0 else { return false }

        var maxMathAscent: CGFloat = 0.0
        var maxMathDescent: CGFloat = 0.0
        storage.enumerateAttribute(
            MarkdownLiveStyler.inlineMathSpanAttributeKey,
            in: NSRange(location: clampedLoc, length: clampedLen),
            options: []
        ) { value, _, _ in
            guard let info = value as? MarkdownLiveStyler.InlineMathLayoutInfo else { return }
            maxMathAscent = max(maxMathAscent, info.ascent)
            maxMathDescent = max(maxMathDescent, info.descent)
        }
        guard maxMathAscent > 0.0 || maxMathDescent > 0.0 else { return false }

        let currentBaseline = baselineOffset.pointee
        let currentHeight = lineFragmentRect.pointee.height
        let currentDescent = max(0.0, currentHeight - currentBaseline)
        let neededAscent = ceil(maxMathAscent + 3.0)
        let neededDescent = ceil(maxMathDescent + 3.0)
        let extraTop = max(0.0, neededAscent - currentBaseline)
        let extraBottom = max(0.0, neededDescent - currentDescent)
        guard extraTop > 0.5 || extraBottom > 0.5 else { return false }

        baselineOffset.pointee = currentBaseline + extraTop
        lineFragmentRect.pointee.size.height = currentHeight + extraTop + extraBottom
        lineFragmentUsedRect.pointee.size.height = max(
            lineFragmentUsedRect.pointee.size.height + extraTop + extraBottom,
            lineFragmentRect.pointee.size.height
        )
        return true
    }

    private func shouldAllowBreak(beforeCharacterAt charIndex: Int, in layoutManager: NSLayoutManager) -> Bool {
        guard charIndex > 0,
              let storage = layoutManager.textStorage,
              charIndex <= storage.length else { return true }
        if let prevInfo = storage.attribute(
            MarkdownLiveStyler.inlineMathSpanAttributeKey,
            at: charIndex - 1,
            effectiveRange: nil
        ) as? MarkdownLiveStyler.InlineMathLayoutInfo {
            if charIndex < NSMaxRange(prevInfo.range) {
                return false
            }
            if charIndex == NSMaxRange(prevInfo.range), charIndex < storage.length {
                let ch = (storage.string as NSString).character(at: charIndex)
                if isAttachedTrailingPunctuation(ch) {
                    return false
                }
            }
        }
        return true
    }

    private func isAttachedTrailingPunctuation(_ unichar: UInt16) -> Bool {
        switch unichar {
        case 44, 46, 59, 58, 33, 63, 41, 93: // , . ; : ! ? ) ]
            return true
        default:
            return false
        }
    }

    private func isSoftLineBreak(at charIndex: Int, in layoutManager: NSLayoutManager) -> Bool {
        guard let storage = layoutManager.textStorage, charIndex < storage.length else { return false }
        return storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: charIndex, effectiveRange: nil) != nil
    }
}
