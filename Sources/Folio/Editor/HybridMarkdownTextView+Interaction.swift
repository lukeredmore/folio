import AppKit
import FolioEngineFFI
import SwiftUI

extension HybridMarkdownTextView {

    private static let taskListMarkerRegex = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*(?:[-*+]|\d+[.)])[ \t]+(\[[ xX]\])(?=[ \t]|$)"#
    )

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mediaHoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mediaHoverTrackingArea = area
    }

    public func imageAltTooltip(at point: NSPoint) -> String? {
        guard !isSourceCodeMode, let layoutManager = self.layoutManager else { return nil }
        let origin = self.textContainerOrigin
        let fullContentWidth = self.bounds.width - origin.x * 2
        let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
        let probeRect = NSRect(x: point.x - 16.0, y: point.y - 16.0, width: 32.0, height: 32.0)
        let visibleChars = visibleDecorationCharacterRange(for: probeRect, margin: 64.0)
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        for dec in lineDecorations {
            if let visibleChars, !Self.decorationSpan(dec.lineRange, touches: visibleChars) {
                continue
            }
            guard case let .imageRendered(url, alt, _, _, _, baseDirectoryURL, _) = dec.kind,
                let layout = resolveMediaCardLayout(
                    for: dec,
                    advanceAnimation: false,
                    layoutManager: layoutManager,
                    origin: origin,
                    contentWidth: contentWidth,
                    imageXOffsetByLineLocation: &imageXOffsetByLineLocation
                )
            else {
                continue
            }
            if layout.rect.contains(point) {
                if layout.image != nil {
                    return alt.isEmpty ? nil : alt
                }
                return FolioMediaImageCache.shared.placeholderInfo(
                    for: url,
                    alt: alt,
                    baseDirectoryURL: baseDirectoryURL,
                    isDark: currentTheme.isDark
                ).tooltipText
            }
        }
        return nil
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hoveredComment = comment(at: point) {
            let tip = hoveredComment.commentText
            if self.toolTip != tip {
                self.toolTip = tip
            }
            NSCursor.pointingHand.set()
            return
        }
        let tip = imageAltTooltip(at: point) ?? latexDecorationTooltip(at: point)
        if self.toolTip != tip {
            self.toolTip = tip
        }
        super.mouseMoved(with: event)
    }

    /// Hit-tests a click at `point` against a rendered Markdown task-list checkbox glyph rect.
    /// Rejects clicks in margins, prose `[x]`, code blocks, inline code, math blocks/spans, and LaTeX files.
    @discardableResult
    func toggleTaskCheckboxIfHit(at point: NSPoint) -> Bool {
        guard !isSourceCodeMode,
            !isEditingLaTeXOrBibTeXDocument,
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer,
            let storage = self.textStorage
        else {
            return false
        }
        let origin = self.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard containerPoint.x >= -2.0, containerPoint.y >= -2.0 else { return false }

        let probeRect = NSRect(x: point.x - 12.0, y: point.y - 12.0, width: 24.0, height: 24.0)
        guard let visibleChars = visibleDecorationCharacterRange(for: probeRect, margin: 32.0),
            visibleChars.length > 0
        else {
            return false
        }

        let nsStr = storage.string as NSString
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return false }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < nsStr.length else { return false }

        let absBoxRange: NSRange
        var attrRange = NSRange()
        if storage.attribute(Self.taskCheckboxStateAttributeKey, at: charIndex, effectiveRange: &attrRange) != nil,
            attrRange.length > 0,
            NSMaxRange(attrRange) <= nsStr.length
        {
            guard storage.attribute(MarkdownLiveStyler.noSpellCheckAttributeKey, at: attrRange.location, effectiveRange: nil) == nil,
                !isCharacterInsideNonProseDecoration(attrRange.location, visibleChars: visibleChars)
            else {
                return false
            }
            absBoxRange = attrRange
        } else {
            let lineRange = nsStr.lineRange(for: NSRange(location: charIndex, length: 0))
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location {
                let ch = nsStr.character(at: contentEnd - 1)
                if ch == 10 || ch == 13 {
                    contentEnd -= 1
                } else {
                    break
                }
            }
            let contentRange = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
            guard contentRange.length >= 5,
                let match = Self.taskListMarkerRegex.firstMatch(in: storage.string, options: [], range: contentRange)
            else {
                return false
            }
            let boxRange = match.range(at: 1)
            guard boxRange.location != NSNotFound, boxRange.length == 3 else { return false }
            guard storage.attribute(MarkdownLiveStyler.noSpellCheckAttributeKey, at: boxRange.location, effectiveRange: nil) == nil,
                storage.attribute(MarkdownLiveStyler.inlineCodeFontAttributeKey, at: boxRange.location, effectiveRange: nil) == nil,
                storage.attribute(MarkdownLiveStyler.inlineMathSpanAttributeKey, at: boxRange.location, effectiveRange: nil) == nil,
                !isCharacterInsideNonProseDecoration(boxRange.location, visibleChars: visibleChars)
            else {
                return false
            }
            absBoxRange = boxRange
        }

        let boxGlyphs = layoutManager.glyphRange(forCharacterRange: absBoxRange, actualCharacterRange: nil)
        guard boxGlyphs.location != NSNotFound, boxGlyphs.length > 0 else { return false }
        let boxRect = layoutManager.boundingRect(forGlyphRange: boxGlyphs, in: textContainer)
            .offsetBy(dx: origin.x, dy: origin.y)
            .insetBy(dx: -2.0, dy: -2.0)
        guard boxRect.contains(point) else { return false }

        onToggleCheckboxAtCharacterIndex?(absBoxRange.location)
        return true
    }

    private func isCharacterInsideNonProseDecoration(_ charIndex: Int, visibleChars: NSRange?) -> Bool {
        for (decIdx, dec) in lineDecorations.enumerated() {
            let span = decorationSpan(at: decIdx)
            if let visibleChars, !Self.decorationSpan(span, touches: visibleChars) {
                continue
            }
            guard NSLocationInRange(charIndex, span) else { continue }
            switch dec.kind {
            case .codeFenceStart, .codeFenceBody, .codeFenceEnd,
                .mathBlockStart, .mathBlockBody, .mathBlockEnd, .mathBlockRendered,
                .mermaidBlockRendered, .svgBlockRendered, .htmlBlockRendered:
                return true
            case let .inlineCode(codeRange, _, _):
                if NSLocationInRange(charIndex, codeRange) { return true }
            case let .inlineMathRendered(_, mathRange, _, _):
                if NSLocationInRange(charIndex, mathRange) { return true }
            default:
                break
            }
        }
        return false
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let diagram = expandableDiagram(at: point) {
            workspaceViewModel?.expandedDiagram = diagram
            return
        }

        if handleVideoClickIfNeeded(at: point) {
            return
        }

        if handleLaTeXDecorationClick(at: point, event: event) {
            return
        }

        if !isSourceCodeMode, let layoutManager = self.layoutManager {
            let origin = self.textContainerOrigin
            let fullContentWidth = self.bounds.width - origin.x * 2
            let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
            let probeRect = NSRect(x: point.x - 16.0, y: point.y - 16.0, width: 32.0, height: 32.0)
            let visibleChars = visibleDecorationCharacterRange(for: probeRect, margin: 64.0)
            for (decIdx, dec) in lineDecorations.enumerated() {
                if let visibleChars, !Self.decorationSpan(decorationSpan(at: decIdx), touches: visibleChars) {
                    continue
                }
                if case .codeFenceStart(let language) = dec.kind,
                    let badge = computeCodeFenceBadgeGeometry(
                        for: dec.lineRange,
                        language: language,
                        layoutManager: layoutManager,
                        origin: origin,
                        contentWidth: contentWidth
                    )
                {
                    if badge.pillRect.insetBy(dx: -4.0, dy: -4.0).contains(point) {
                        presentCodeFenceLanguageMenu(
                            for: dec.lineRange,
                            currentLanguage: language,
                            badgeRect: badge.pillRect
                        )
                        return
                    }
                }
            }
        }

        if toggleTaskCheckboxIfHit(at: point) {
            return
        }

        let charIndex = characterIndexForInsertion(at: point)
        let clickedCommentBeforeDrag = comment(at: point)

        if event.modifierFlags.contains(.shift) {
            let existingSel = self.selectedRange()
            if mouseSelectionAnchorCharIndex == nil {
                mouseSelectionAnchorCharIndex = existingSel.location
            }
        } else {
            mouseSelectionAnchorCharIndex = charIndex
        }
        super.mouseDown(with: event)
        mouseSelectionAnchorCharIndex = nil

        if self.selectedRange().length == 0 {
            if let clickedComment = clickedCommentBeforeDrag {
                workspaceViewModel?.handleCommentHighlightClick(clickedComment)
            } else if workspaceViewModel?.activeCommentID != nil {
                workspaceViewModel?.activeCommentID = nil
                self.needsDisplay = true
            }
        }
    }

    public override func insertNewline(_ sender: Any?) {
        if isEditingLaTeXDocument, tryContinueLaTeXItemOnNewline() {
            return
        }
        let sel = self.selectedRange()
        let nsStr = self.string as NSString
        guard sel.location <= nsStr.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = nsStr.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineUpToCursor = nsStr.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))

        let action = lineUpToCursor.withCString { cStr in
            ot_engine_newline_continuation(cStr)
        }
        defer {
            ot_engine_free_newline_action(action)
        }

        switch action.kind {
        case 1:
            if shouldChangeText(in: lineRange, replacementString: "\n") {
                replaceCharacters(in: lineRange, with: "\n")
                didChangeText()
            }
            return
        case 2:
            if let prefixPtr = action.prefix {
                let prefix = String(cString: prefixPtr)
                super.insertNewline(sender)
                insertText(prefix, replacementRange: self.selectedRange())
                return
            }
        default:
            break
        }

        super.insertNewline(sender)
        startNewParagraphIfSoftBreak()
    }

    /// In live mode a single newline inside a paragraph is a soft break and renders as a space,
    /// so Return would look like it did nothing. Insert a second newline to start a new paragraph.
    func startNewParagraphIfSoftBreak() {
        guard !isSourceCodeMode, let storage = textStorage else { return }
        let location = selectedRange().location
        guard location > 0, location <= storage.length,
            (storage.string as NSString).character(at: location - 1) == 10,
            storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: location - 1, effectiveRange: nil) != nil
        else {
            return
        }
        insertText("\n", replacementRange: selectedRange())
    }

    public func centerSelectionIfTypewriter() {
        guard isTypewriterMode,
            let layoutManager = self.layoutManager,
            let textContainer = self.textContainer,
            let scrollView = self.enclosingScrollView
        else {
            return
        }
        let sel = self.selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: sel, actualCharacterRange: nil)
        let caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = max(0, caretRect.midY + textContainerOrigin.y - visibleHeight * 0.45)
        let currentX = scrollView.contentView.bounds.origin.x
        scrollView.contentView.scroll(to: NSPoint(x: currentX, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc public func toggleSidebar(_ sender: Any?) {
        workspaceViewModel?.showSidebar.toggle()
    }

    public override func printView(_ sender: Any?) {
        if let vm = workspaceViewModel {
            vm.printDocument()
        } else {
            super.printView(sender)
        }
    }

    public override func performFindPanelAction(_ sender: Any?) {
        guard let vm = workspaceViewModel else {
            super.performFindPanelAction(sender)
            return
        }
        let tag = (sender as? NSMenuItem)?.tag ?? 1
        switch tag {
        case 2:
            vm.findNextInDocument()
        case 3:
            vm.findPreviousInDocument()
        case 4:
            vm.replaceAllInDocument()
        case 5, 6:
            vm.replaceCurrentMatch()
        case 12:
            vm.openDocumentFind(withReplace: true)
        default:
            vm.openDocumentFind(withReplace: false)
        }
    }
}
