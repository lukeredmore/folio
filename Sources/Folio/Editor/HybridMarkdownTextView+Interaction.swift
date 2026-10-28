import AppKit
import FolioEngineFFI
import SwiftUI

extension HybridMarkdownTextView {

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
        var imageXOffsetByLineLocation: [Int: CGFloat] = [:]

        for dec in lineDecorations {
            guard case let .imageRendered(url, alt, fullRange, explicitWidth, explicitHeight, baseDirectoryURL, _) = dec.kind else {
                continue
            }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: dec.lineRange, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
            let lineFrag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let imgGlyphIdx = layoutManager.glyphIndexForCharacter(at: fullRange.location)
            let glyphX =
                (imgGlyphIdx != NSNotFound && imgGlyphIdx < layoutManager.numberOfGlyphs)
                ? layoutManager.location(forGlyphAt: imgGlyphIdx).x
                : 0.0
            let lineKey = dec.lineRange.location
            let currentOffset = imageXOffsetByLineLocation[lineKey] ?? 0.0
            let startX = origin.x + max(glyphX, currentOffset)
            let remainingWidth = max(80.0, (origin.x + contentWidth) - startX)

            let loadedImg = FolioMediaImageCache.shared.image(
                for: url,
                baseDirectoryURL: baseDirectoryURL,
                isDark: currentTheme.isDark
            )

            let hitRect: NSRect
            if let img = loadedImg, img.size.width > 0, img.size.height > 0 {
                let intrinsicSize = img.size
                let aspect = intrinsicSize.height / max(1.0, intrinsicSize.width)
                let targetW: CGFloat
                let targetH: CGFloat
                if let ew = explicitWidth, let eh = explicitHeight {
                    targetW = ew
                    targetH = eh
                } else if let ew = explicitWidth {
                    targetW = ew
                    targetH = round(ew * aspect)
                } else if let eh = explicitHeight {
                    targetH = eh
                    targetW = round(eh / max(0.01, aspect))
                } else {
                    targetW = intrinsicSize.width
                    targetH = intrinsicSize.height
                }
                let maxDrawH = max(18.0, lineFrag.height - 6.0)
                let scale = min(1.0, min(remainingWidth / max(1.0, targetW), maxDrawH / max(1.0, targetH)))
                let drawW = targetW * scale
                let drawH = targetH * scale
                hitRect = NSRect(
                    x: startX,
                    y: origin.y + lineFrag.minY + (lineFrag.height - drawH) * 0.5,
                    width: drawW,
                    height: drawH
                )
                imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + drawW + 8.0
            } else {
                let cardWidth = min(remainingWidth, max(200.0, min(380.0, explicitWidth ?? 360.0)))
                let cardHeight = min(50.0, max(38.0, lineFrag.height - 6.0))
                hitRect = NSRect(
                    x: startX,
                    y: origin.y + lineFrag.minY + (lineFrag.height - cardHeight) * 0.5,
                    width: cardWidth,
                    height: cardHeight
                )
                imageXOffsetByLineLocation[lineKey] = (startX - origin.x) + cardWidth + 8.0
            }

            if hitRect.contains(point) {
                return alt.isEmpty ? nil : alt
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

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 0. Expand button on a rendered Mermaid diagram opens the zoom sheet
        if let diagram = expandableDiagram(at: point) {
            workspaceViewModel?.expandedDiagram = diagram
            return
        }

        // 0b. Click on a rendered video starts/toggles inline playback without unfolding the line
        if handleVideoClickIfNeeded(at: point) {
            return
        }

        // 0c. Click on a LaTeX preamble banner, \input card, or citation/reference pill
        if handleLaTeXDecorationClick(at: point, event: event) {
            return
        }

        // 1. Hit-test code fence language selector badge on the right
        if !isSourceCodeMode, let layoutManager = self.layoutManager {
            let origin = self.textContainerOrigin
            let fullContentWidth = self.bounds.width - origin.x * 2
            let contentWidth = proseColumnWidth > 0 ? proseColumnWidth : fullContentWidth
            for dec in lineDecorations {
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

        // 2. Hit-test task list checkboxes
        let charIndex = characterIndexForInsertion(at: point)
        let nsStr = self.string as NSString

        if charIndex < nsStr.length {
            let lineRange = nsStr.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineStr = nsStr.substring(with: lineRange)
            if let rangeOfBox = lineStr.range(of: #"\[[ xX]\]"#, options: .regularExpression) {
                let nsBoxRange = NSRange(rangeOfBox, in: lineStr)
                let absBoxRange = NSRange(location: lineRange.location + nsBoxRange.location, length: nsBoxRange.length)
                let expandedHitRange = NSRange(
                    location: max(0, absBoxRange.location - 2),
                    length: min(nsStr.length - max(0, absBoxRange.location - 2), absBoxRange.length + 3)
                )
                if NSLocationInRange(charIndex, expandedHitRange) {
                    onToggleCheckboxAtCharacterIndex?(absBoxRange.location)
                    return
                }
            }
        }

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

        // 3. If the user clicked (without dragging a selection) on a commented highlight, link/focus that comment
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
        if tryContinueLaTeXItemOnNewline() {
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
        case 2: // NSFindPanelAction.next
            vm.findNextInDocument()
        case 3: // NSFindPanelAction.previous
            vm.findPreviousInDocument()
        case 4: // NSFindPanelAction.replaceAll
            vm.replaceAllInDocument()
        case 5, 6: // NSFindPanelAction.replace, replaceAndFind
            vm.replaceCurrentMatch()
        case 12: // NSFindPanelAction.showReplaceInterface
            vm.openDocumentFind(withReplace: true)
        default:
            vm.openDocumentFind(withReplace: false)
        }
    }
}
