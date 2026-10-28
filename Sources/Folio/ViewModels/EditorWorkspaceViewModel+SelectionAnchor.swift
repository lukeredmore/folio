import AppKit
import Foundation

@MainActor
extension EditorWorkspaceViewModel {
    // MARK: - Selection Stats & Direction Tracking
    public func refreshTooltipAnchorOnViewportChangeIfNeeded() {
        if selectionTooltipAnchor != nil || currentSelectedRange.length > 0 || activeCommentDraftRange != nil {
            updateSelectionTooltipAnchor()
        }
    }

    public func handleTextViewSelectionChange(in tv: HybridMarkdownTextView, selectedRange sel: NSRange) {
        let explicitDirection: SelectionDirection?
        if sel.length == 0 {
            explicitDirection = .forward
        } else if let anchor = tv.mouseSelectionAnchorCharIndex {
            explicitDirection = (sel.location < anchor && NSMaxRange(sel) <= anchor + 1) ? .backward : .forward
        } else if tv.selectionAffinity == .upstream {
            explicitDirection = .backward
        } else {
            explicitDirection = nil
        }
        if let explicitDirection {
            tv.detectedSelectionDirection = explicitDirection
        }
        updateSelectionStats(selectedRange: sel, direction: explicitDirection)
    }

    public func updateSelectionStats(
        selectedRange: NSRange,
        direction: SelectionDirection? = nil
    ) {
        let previousRange = currentSelectedRange
        if selectedRange != previousRange && !isLiveKeystrokeInProgress {
            canCoalesceLiveTyping = false
        }
        currentSelectedRange = selectedRange
        if let direction {
            currentSelectionDirection = direction
        } else if selectedRange.length == 0 {
            currentSelectionDirection = .forward
        } else if selectedRange.location < previousRange.location,
                  NSMaxRange(selectedRange) <= NSMaxRange(previousRange) {
            currentSelectionDirection = .backward
        } else if selectedRange.location > previousRange.location,
                  NSMaxRange(selectedRange) == NSMaxRange(previousRange),
                  currentSelectionDirection == .backward {
            currentSelectionDirection = .backward
        } else {
            currentSelectionDirection = .forward
        }
        if !isRestoringState && autoSaveDelay <= 0 {
            setSessionValue(selectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        }
        if selectedRange.length > 0 || stats.selectedCharacters > 0 {
            let updatedStats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
            if stats != updatedStats {
                stats = updatedStats
            }
        }
        updateSelectionTooltipAnchor(for: selectedRange, direction: currentSelectionDirection)
    }

    // MARK: - Selection Comment Reconciliation & Tooltip Anchor
    internal func reconcileSelectionComments(from oldText: String, to newText: String) {
        guard !selectionComments.isEmpty else { return }
        let oldNS = oldText as NSString
        let newNS = newText as NSString
        let delta = newNS.length - oldNS.length

        // Find common prefix length to locate edit point
        var prefixLen = 0
        let minLen = min(oldNS.length, newNS.length)
        while prefixLen < minLen && oldNS.character(at: prefixLen) == newNS.character(at: prefixLen) {
            prefixLen += 1
        }

        let previousComments = selectionComments
        var updated: [SelectionComment] = []
        updated.reserveCapacity(selectionComments.count)

        for var comment in selectionComments {
            let safeLoc = max(0, min(comment.range.location, newNS.length))
            let safeLen = max(0, min(comment.range.length, newNS.length - safeLoc))
            let directCandidate = NSRange(location: safeLoc, length: safeLen)

            if directCandidate.length == comment.range.length,
               newNS.substring(with: directCandidate) == comment.selectedRawText {
                comment.range = directCandidate
                updated.append(comment)
                continue
            }

            if comment.range.location >= prefixLen {
                let shiftedLoc = comment.range.location + delta
                if shiftedLoc >= 0, shiftedLoc + comment.range.length <= newNS.length {
                    let shiftedCandidate = NSRange(location: shiftedLoc, length: comment.range.length)
                    if newNS.substring(with: shiftedCandidate) == comment.selectedRawText {
                        comment.range = shiftedCandidate
                        updated.append(comment)
                        continue
                    }
                }
            }

            // Fallback: locate the nearest occurrence of the commented markdown text
            let found = newNS.range(of: comment.selectedRawText)
            if found.location != NSNotFound && found.length > 0 {
                comment.range = found
                updated.append(comment)
            }
        }

        selectionComments = updated
        if updated != previousComments {
            autoSaveCompanionCommentsIfNeeded()
        }
    }

    public func updateSelectionTooltipAnchor(
        for selectedRange: NSRange? = nil,
        direction: SelectionDirection? = nil
    ) {
        let range = selectedRange ?? activeCommentDraftRange ?? currentSelectedRange
        let effectiveDirection = direction ?? currentSelectionDirection
        let nsText = markdownText as NSString
        let clampedLoc = max(0, min(range.location, nsText.length))
        let clampedLen = max(0, min(range.length, nsText.length - clampedLoc))
        let clampedRange = NSRange(location: clampedLoc, length: clampedLen)

        if let draftRange = activeCommentDraftRange, draftRange != clampedRange {
            if clampedRange.length == 0 {
                if activeCommentDraftRange != nil {
                    activeCommentDraftRange = nil
                }
                if !activeCommentDraftText.isEmpty {
                    activeCommentDraftText = ""
                }
            } else {
                if activeCommentDraftRange != clampedRange {
                    activeCommentDraftRange = clampedRange
                }
                let nextDraftText = existingComment(overlapping: clampedRange)?.commentText ?? activeCommentDraftText
                if activeCommentDraftText != nextDraftText {
                    activeCommentDraftText = nextDraftText
                }
            }
        }

        guard clampedRange.length > 0 else {
            if selectionTooltipAnchor != nil {
                selectionTooltipAnchor = nil
            }
            return
        }

        let selectedSubstring = nsText.substring(with: clampedRange)
        guard !selectedSubstring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if selectionTooltipAnchor != nil {
                selectionTooltipAnchor = nil
            }
            return
        }

        let nextAnchor: SelectionTooltipAnchor?
        if let textView = activeTextView {
            nextAnchor = textView.selectionTooltipAnchor(for: clampedRange, direction: effectiveDirection)
        } else {
            let defaultRect = CGRect(x: 160, y: 80, width: 120, height: 22)
            nextAnchor = SelectionTooltipAnchor(
                range: clampedRange,
                selectionRectInViewport: defaultRect,
                headRectInViewport: CGRect(x: 272, y: 80, width: 8, height: 22),
                direction: effectiveDirection,
                viewportSize: CGSize(width: 720, height: 480)
            )
        }
        if selectionTooltipAnchor != nextAnchor {
            selectionTooltipAnchor = nextAnchor
        }
    }

    // MARK: - Right Sidebar & Clickable Comment Highlight Navigation

    public var isCommentsSidebarVisible: Bool {
        showCommentsSidebar && !selectionComments.isEmpty
    }

    public func comment(atCharacterIndex charIndex: Int) -> SelectionComment? {
        guard charIndex >= 0 else { return nil }
        return selectionComments.first { comment in
            NSLocationInRange(charIndex, comment.range)
        }
    }

    /// Links a clicked highlight in the editor to its comment in the right sidebar.
    public func handleCommentHighlightClick(_ comment: SelectionComment) {
        if activeCommentID != comment.id {
            activeCommentID = comment.id
        }
        if !showCommentsSidebar {
            showCommentsSidebar = true
        }
        activeTextView?.needsDisplay = true
    }

    /// Focuses a comment from the right sidebar list and scrolls the editor to its highlighted range.
    public func focusComment(_ comment: SelectionComment, scrollEditor: Bool = true) {
        if activeCommentID != comment.id {
            activeCommentID = comment.id
        }
        if !showCommentsSidebar {
            showCommentsSidebar = true
        }
        let nsLen = (markdownText as NSString).length
        let loc = max(0, min(comment.range.location, nsLen))
        let len = max(0, min(comment.range.length, nsLen - loc))
        guard len > 0 else { return }
        let safeRange = NSRange(location: loc, length: len)
        if scrollEditor, let tv = activeTextView {
            tv.scrollRangeToVisible(safeRange)
            tv.needsDisplay = true
        } else {
            activeTextView?.needsDisplay = true
        }
    }
}
