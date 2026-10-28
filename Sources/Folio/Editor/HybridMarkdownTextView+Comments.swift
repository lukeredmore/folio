import AppKit
import SwiftUI

extension HybridMarkdownTextView {

    // MARK: - Selection Tooltip Viewport Geometry

    public func selectionTooltipAnchor(
        for range: NSRange,
        direction: SelectionDirection? = nil
    ) -> SelectionTooltipAnchor? {
        let resolvedDirection = direction ?? detectedSelectionDirection
        let nsLen = (self.string as NSString).length
        let clampedLoc = max(0, min(range.location, nsLen))
        let clampedLen = max(0, min(range.length, nsLen - clampedLoc))
        guard clampedLen > 0 else { return nil }
        let safeRange = NSRange(location: clampedLoc, length: clampedLen)

        guard let layoutManager = self.layoutManager,
            let textContainer = self.textContainer
        else {
            let fallbackRect = NSRect(x: 120, y: 80, width: 160, height: 22)
            return SelectionTooltipAnchor(
                range: safeRange,
                selectionRectInViewport: fallbackRect,
                headRectInViewport: fallbackRect,
                direction: resolvedDirection,
                viewportSize: NSSize(width: 800, height: 600)
            )
        }

        layoutManager.ensureLayout(forCharacterRange: safeRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
            return nil
        }

        let origin = self.textContainerOrigin
        var bounding = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        bounding.origin.x += origin.x
        bounding.origin.y += origin.y
        bounding.size.width = max(16.0, bounding.size.width)
        bounding.size.height = max(18.0, bounding.size.height)

        let headGlyphIndex =
            resolvedDirection == .backward
            ? glyphRange.location
            : max(glyphRange.location, NSMaxRange(glyphRange) - 1)
        var headBounding = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: headGlyphIndex, length: 1),
            in: textContainer
        )
        headBounding.origin.x += origin.x
        headBounding.origin.y += origin.y
        headBounding.size.width = max(8.0, headBounding.size.width)
        headBounding.size.height = max(18.0, headBounding.size.height)

        if let scrollView = self.enclosingScrollView {
            let clipBounds = scrollView.contentView.bounds
            let rawViewportSize =
                clipBounds.size.width > 10 && clipBounds.size.height > 10
                ? clipBounds.size
                : (scrollView.bounds.size.width > 10 && scrollView.bounds.size.height > 10
                    ? scrollView.bounds.size
                    : NSSize(width: max(800, self.bounds.width), height: max(600, self.bounds.height)))

            let rectInViewport = NSRect(
                x: bounding.origin.x - clipBounds.origin.x,
                y: bounding.origin.y - clipBounds.origin.y,
                width: bounding.width,
                height: bounding.height
            )
            let headRectInViewport = NSRect(
                x: headBounding.origin.x - clipBounds.origin.x,
                y: headBounding.origin.y - clipBounds.origin.y,
                width: headBounding.width,
                height: headBounding.height
            )

            // Hide floating tooltip if the selection is scrolled completely out of the visible clip view
            if clipBounds.size.height > 10 {
                if rectInViewport.maxY < -8.0 || rectInViewport.minY > rawViewportSize.height + 8.0 {
                    return nil
                }
            }

            return SelectionTooltipAnchor(
                range: safeRange,
                selectionRectInViewport: rectInViewport,
                headRectInViewport: headRectInViewport,
                direction: resolvedDirection,
                viewportSize: rawViewportSize
            )
        }

        let fallbackViewport = NSSize(
            width: max(800, self.bounds.width),
            height: max(600, self.bounds.height)
        )
        return SelectionTooltipAnchor(
            range: safeRange,
            selectionRectInViewport: bounding,
            headRectInViewport: headBounding,
            direction: resolvedDirection,
            viewportSize: fallbackViewport
        )
    }

    // MARK: - Background Highlight Drawing for External Updates & Selection Comments

    func drawExternalUpdateAndCommentHighlights(
        in dirtyRect: NSRect,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: NSPoint,
        contentWidth: CGFloat
    ) {
        let nsLen = (self.string as NSString).length

        // 1. Visual highlights for lines recently updated externally on disk / remote sync
        if !externalUpdateHighlightRanges.isEmpty {
            let highlightFill =
                currentTheme.isDark
                ? NSColor.systemGreen.withAlphaComponent(0.14)
                : NSColor.systemGreen.withAlphaComponent(0.10)
            let highlightBar =
                currentTheme.isDark
                ? NSColor.systemGreen.withAlphaComponent(0.85)
                : NSColor.systemGreen.withAlphaComponent(0.75)

            for rawRange in externalUpdateHighlightRanges {
                let clampedLoc = max(0, min(rawRange.location, nsLen))
                let clampedLen = max(0, min(rawRange.length, nsLen - clampedLoc))
                let safeRange = NSRange(location: clampedLoc, length: clampedLen)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
                guard glyphRange.location != NSNotFound else { continue }
                var boxRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                boxRect.origin.x = origin.x - 10.0
                boxRect.origin.y += origin.y
                boxRect.size.width = contentWidth + 20.0
                boxRect.size.height = max(20.0, boxRect.size.height)
                guard boxRect.insetBy(dx: -20, dy: -30).intersects(dirtyRect) else { continue }

                highlightFill.setFill()
                NSBezierPath(roundedRect: boxRect, xRadius: 5.0, yRadius: 5.0).fill()

                let barRect = NSRect(
                    x: origin.x - 10.0,
                    y: boxRect.minY + 1.0,
                    width: 3.5,
                    height: max(4.0, boxRect.height - 2.0)
                )
                highlightBar.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.75, yRadius: 1.75).fill()
            }
        }

        // 2. Selection comments highlights (with active/linked visual state)
        let visibleChars = visibleDecorationCharacterRange(for: dirtyRect)
        let linkColor = currentTheme.linkNSColor
        if let comments = workspaceViewModel?.selectionComments, !comments.isEmpty {
            let activeCommentID = workspaceViewModel?.activeCommentID
            let baseFill = linkColor.withAlphaComponent(currentTheme.isDark ? 0.16 : 0.11)
            let baseUnderline = linkColor.withAlphaComponent(currentTheme.isDark ? 0.55 : 0.45)
            let activeFill = linkColor.withAlphaComponent(currentTheme.isDark ? 0.26 : 0.18)
            let activeUnderline = linkColor.withAlphaComponent(0.90)
            let activeStroke = linkColor.withAlphaComponent(0.60)

            for comment in comments {
                if let visible = visibleChars, !Self.decorationSpan(comment.range, touches: visible) {
                    continue
                }
                let isActive = (comment.id == activeCommentID)
                drawCharacterRangeHighlight(
                    comment.range, nsLength: nsLen, in: dirtyRect,
                    layoutManager: layoutManager, textContainer: textContainer, origin: origin,
                    fillColor: isActive ? activeFill : baseFill,
                    underlineColor: isActive ? activeUnderline : baseUnderline,
                    strokeColor: isActive ? activeStroke : nil
                )
            }
        }

        // 3. Active comment draft range highlight (keeps target passage visibly highlighted while typing in tooltip)
        if let draftRange = workspaceViewModel?.activeCommentDraftRange, draftRange.length > 0 {
            if visibleChars == nil || Self.decorationSpan(draftRange, touches: visibleChars!) {
                let draftFill = linkColor.withAlphaComponent(currentTheme.isDark ? 0.22 : 0.15)
                let draftUnderline = linkColor.withAlphaComponent(0.80)
                drawCharacterRangeHighlight(
                    draftRange, nsLength: nsLen, in: dirtyRect,
                    layoutManager: layoutManager, textContainer: textContainer, origin: origin,
                    fillColor: draftFill, underlineColor: draftUnderline, strokeColor: nil
                )
            }
        }
    }

    public func comment(at point: NSPoint) -> SelectionComment? {
        guard let comments = workspaceViewModel?.selectionComments, !comments.isEmpty else { return nil }
        let nsLen = (self.string as NSString).length
        guard nsLen > 0 else { return nil }

        if let layoutManager = self.layoutManager, let textContainer = self.textContainer {
            let origin = self.textContainerOrigin
            let probeRect = NSRect(x: point.x - 16.0, y: point.y - 16.0, width: 32.0, height: 32.0)
            let nearChars = visibleDecorationCharacterRange(for: probeRect)
            for comment in comments {
                if let nearChars, !Self.decorationSpan(comment.range, touches: nearChars) {
                    continue
                }
                let rects = commentPieceRects(
                    for: comment.range, nsLength: nsLen,
                    layoutManager: layoutManager, textContainer: textContainer, origin: origin,
                    ensureLayoutIfNeeded: false
                )
                if rects.contains(where: { $0.insetBy(dx: -3.0, dy: -2.0).contains(point) }) {
                    return comment
                }
            }
        }

        let charIndex = characterIndexForInsertion(at: point)
        guard charIndex < nsLen else { return nil }
        return comments.first { NSLocationInRange(charIndex, $0.range) }
    }

    @discardableResult
    public func handleClickOnCommentHighlight(at point: NSPoint) -> SelectionComment? {
        guard let clicked = comment(at: point) else { return nil }
        workspaceViewModel?.handleCommentHighlightClick(clicked)
        return clicked
    }

    func commentPieceRects(
        for rawRange: NSRange, nsLength: Int,
        layoutManager: NSLayoutManager, textContainer: NSTextContainer, origin: NSPoint,
        ensureLayoutIfNeeded: Bool = true
    ) -> [NSRect] {
        let clampedLoc = max(0, min(rawRange.location, nsLength))
        let clampedLen = max(0, min(rawRange.length, nsLength - clampedLoc))
        guard clampedLen > 0 else { return [] }
        let safeRange = NSRange(location: clampedLoc, length: clampedLen)
        if ensureLayoutIfNeeded {
            layoutManager.ensureLayout(forCharacterRange: safeRange)
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: safeRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return [] }

        var rects: [NSRect] = []
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineFragmentGlyphRange = NSRange()
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineFragmentGlyphRange)
            let pieceGlyphs = NSIntersectionRange(lineFragmentGlyphRange, glyphRange)
            guard pieceGlyphs.length > 0 else { break }
            var pieceRect = layoutManager.boundingRect(forGlyphRange: pieceGlyphs, in: textContainer)
            pieceRect.origin.x += origin.x
            pieceRect.origin.y += origin.y
            rects.append(pieceRect.insetBy(dx: -2.0, dy: -1.0))
            glyphIndex = NSMaxRange(pieceGlyphs)
        }
        return rects
    }

    private func drawCharacterRangeHighlight(
        _ rawRange: NSRange, nsLength: Int, in dirtyRect: NSRect,
        layoutManager: NSLayoutManager, textContainer: NSTextContainer, origin: NSPoint,
        fillColor: NSColor, underlineColor: NSColor, strokeColor: NSColor?
    ) {
        let pieceRects = commentPieceRects(
            for: rawRange, nsLength: nsLength,
            layoutManager: layoutManager, textContainer: textContainer, origin: origin,
            ensureLayoutIfNeeded: false
        )
        for pieceRect in pieceRects where pieceRect.intersects(dirtyRect) {
            let rounded = NSBezierPath(roundedRect: pieceRect, xRadius: 3.5, yRadius: 3.5)
            fillColor.setFill()
            rounded.fill()
            if let strokeColor {
                strokeColor.setStroke()
                rounded.lineWidth = 1.0
                rounded.stroke()
            }
            let underlineHeight: CGFloat = strokeColor != nil ? 2.2 : 1.5
            let underlineRect = NSRect(
                x: pieceRect.minX + 1.0, y: pieceRect.maxY - underlineHeight,
                width: max(2.0, pieceRect.width - 2.0), height: underlineHeight
            )
            underlineColor.setFill()
            NSBezierPath(roundedRect: underlineRect, xRadius: 0.75, yRadius: 0.75).fill()
        }
    }

    // MARK: - Context Menu Actions for Selected Text

    public override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()
        guard self.selectedRange().length > 0 else { return baseMenu }

        let commentItem = NSMenuItem(title: "Add Comment on Selection…", action: #selector(handleContextMenuAddComment(_:)), keyEquivalent: "")
        commentItem.target = self
        let copyFormattedItem = NSMenuItem(title: "Copy Formatted", action: #selector(handleContextMenuCopyFormatted(_:)), keyEquivalent: "")
        copyFormattedItem.target = self
        let copyRawItem = NSMenuItem(title: "Copy Raw Markdown", action: #selector(handleContextMenuCopyRaw(_:)), keyEquivalent: "")
        copyRawItem.target = self

        baseMenu.insertItem(.separator(), at: 0)
        baseMenu.insertItem(copyRawItem, at: 0)
        baseMenu.insertItem(copyFormattedItem, at: 0)
        baseMenu.insertItem(commentItem, at: 0)
        return baseMenu
    }

    @objc func handleContextMenuAddComment(_ sender: Any?) {
        workspaceViewModel?.beginCommentOnCurrentSelection()
    }

    @objc func handleContextMenuCopyFormatted(_ sender: Any?) {
        workspaceViewModel?.copySelectionFormatted()
    }

    @objc func handleContextMenuCopyRaw(_ sender: Any?) {
        workspaceViewModel?.copySelectionRaw()
    }
}
