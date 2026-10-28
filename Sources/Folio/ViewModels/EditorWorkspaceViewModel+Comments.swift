import AppKit
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Selection Copy Actions ("Copy Formatted" & "Copy Raw")

    public var hasNonEmptySelectionForTooltip: Bool {
        guard let range = effectiveCommentTargetRange() else { return false }
        return range.length > 0
    }

    public func effectiveCommentTargetRange(for explicitRange: NSRange? = nil) -> NSRange? {
        let nsLen = (markdownText as NSString).length
        if let explicitRange, explicitRange.length > 0 {
            let loc = max(0, min(explicitRange.location, nsLen))
            let len = max(0, min(explicitRange.length, nsLen - loc))
            if len > 0 {
                return NSRange(location: loc, length: len)
            }
        }
        if let draftRange = activeCommentDraftRange {
            let loc = max(0, min(draftRange.location, nsLen))
            let len = max(0, min(draftRange.length, nsLen - loc))
            if len > 0 {
                return NSRange(location: loc, length: len)
            }
        }
        let rawSel = activeTextView?.selectedRange() ?? currentSelectedRange
        let loc = max(0, min(rawSel.location, nsLen))
        let len = max(0, min(rawSel.length, nsLen - loc))
        guard len > 0 else { return nil }
        return NSRange(location: loc, length: len)
    }

    @discardableResult
    public func copySelectionFormatted(
        for explicitRange: NSRange? = nil,
        to pasteboard: NSPasteboard = .general
    ) -> String? {
        guard let range = effectiveCommentTargetRange(for: explicitRange) else { return nil }
        return MarkdownCopyFormatter.copyFormatted(
            in: markdownText,
            range: range,
            theme: theme,
            typography: typography,
            pasteboard: pasteboard
        )
    }

    @discardableResult
    public func copySelectionRaw(
        for explicitRange: NSRange? = nil,
        to pasteboard: NSPasteboard = .general
    ) -> String? {
        guard let range = effectiveCommentTargetRange(for: explicitRange) else { return nil }
        return MarkdownCopyFormatter.copyRaw(in: markdownText, range: range, pasteboard: pasteboard)
    }

    // MARK: - Companion Comments File Persistence (`<filename>.comments.folio.md`)

    public var currentCompanionCommentsURL: URL? {
        guard let fileURL = currentFileURL else { return nil }
        return SelectionComment.companionCommentsURL(for: fileURL)
    }

    public func loadCompanionComments(for fileURL: URL?, documentText: String) {
        guard let fileURL else {
            selectionComments = []
            activeCommentID = nil
            return
        }
        let fm = FileManager.default
        for candidateURL in SelectionComment.candidateCompanionURLs(for: fileURL) {
            if fm.fileExists(atPath: candidateURL.path),
                let rawCompanion = try? String(contentsOf: candidateURL, encoding: .utf8)
            {
                selectionComments = SelectionComment.parseCompanionMarkdown(
                    rawCompanion,
                    inDocumentText: documentText,
                    theme: theme,
                    typography: typography
                )
                activeCommentID = selectionComments.first?.id
                if !selectionComments.isEmpty {
                    showCommentsSidebar = true
                }
                return
            }
        }
        selectionComments = []
        activeCommentID = nil
    }

    public func saveCompanionCommentsToDisk(for explicitFileURL: URL? = nil) {
        guard let fileURL = explicitFileURL ?? currentFileURL else { return }
        let fm = FileManager.default
        let primaryURL = SelectionComment.companionCommentsURL(for: fileURL)

        if selectionComments.isEmpty {
            for candidateURL in SelectionComment.candidateCompanionURLs(for: fileURL) {
                if fm.fileExists(atPath: candidateURL.path) {
                    try? fm.removeItem(at: candidateURL)
                }
            }
            return
        }

        let content = SelectionComment.serializeCompanionMarkdown(
            selectionComments,
            documentTitle: fileURL.lastPathComponent,
            fileURL: fileURL,
            workspaceFolderURL: workspaceFolderURL,
            documentText: markdownText
        )
        guard !content.isEmpty else { return }

        do {
            let utf8Data = Data(content.utf8)
            if fm.fileExists(atPath: primaryURL.path) {
                try utf8Data.write(to: primaryURL)
            } else {
                try utf8Data.write(to: primaryURL, options: .atomic)
            }
            if remoteWorkspaceManager.isRemoteURL(primaryURL) {
                enqueueRemoteUpload(content, to: primaryURL)
            }
        } catch {
            NSSound.beep()
        }
    }

    func autoSaveCompanionCommentsIfNeeded() {
        guard !isRestoringState, autoSaveEnabled, activeConflict == nil else { return }
        saveCompanionCommentsToDisk()
    }

    // MARK: - Selection Comments Lifecycle

    public func existingComment(overlapping range: NSRange) -> SelectionComment? {
        if let exact = selectionComments.first(where: { $0.range == range }) {
            return exact
        }
        return selectionComments.first { comment in
            NSIntersectionRange(comment.range, range).length > 0
        }
    }

    public func beginCommentOnCurrentSelection(for explicitRange: NSRange? = nil) {
        guard let range = effectiveCommentTargetRange(for: explicitRange) else { return }
        activeCommentDraftRange = range
        if let existing = existingComment(overlapping: range) {
            activeCommentDraftText = existing.commentText
        } else {
            activeCommentDraftText = ""
        }
        updateSelectionTooltipAnchor(for: range)
        activeTextView?.needsDisplay = true
    }

    public func cancelCommentDraft() {
        activeCommentDraftRange = nil
        activeCommentDraftText = ""
        let sel = activeTextView?.selectedRange() ?? currentSelectedRange
        updateSelectionTooltipAnchor(for: sel)
        activeTextView?.needsDisplay = true
        if let tv = activeTextView, let window = tv.window {
            window.makeFirstResponder(tv)
        }
    }

    @discardableResult
    public func addOrUpdateSelectionComment(
        _ explicitText: String? = nil,
        for explicitRange: NSRange? = nil
    ) -> SelectionComment? {
        let trimmedComment = (explicitText ?? activeCommentDraftText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedComment.isEmpty,
            let range = explicitRange ?? effectiveCommentTargetRange(),
            range.length > 0
        else {
            return nil
        }

        let rawSelected = MarkdownCopyFormatter.rawMarkdown(in: markdownText, range: range)
        let formattedSelected = MarkdownCopyFormatter.strippedPlainText(
            in: markdownText,
            range: range,
            theme: theme,
            typography: typography
        )

        let savedComment: SelectionComment
        if let idx = selectionComments.firstIndex(where: { $0.range == range || NSIntersectionRange($0.range, range).length > 0 }) {
            var updated = selectionComments[idx]
            updated.range = range
            updated.selectedRawText = rawSelected
            updated.selectedFormattedText = formattedSelected
            updated.commentText = trimmedComment
            selectionComments[idx] = updated
            savedComment = updated
        } else {
            let newComment = SelectionComment(
                range: range,
                selectedRawText: rawSelected,
                selectedFormattedText: formattedSelected,
                commentText: trimmedComment
            )
            selectionComments.append(newComment)
            savedComment = newComment
        }

        selectionComments.sort { a, b in
            if a.range.location != b.range.location {
                return a.range.location < b.range.location
            }
            return a.createdAt < b.createdAt
        }

        activeCommentID = savedComment.id
        showCommentsSidebar = true
        activeCommentDraftRange = nil
        activeCommentDraftText = ""
        autoSaveCompanionCommentsIfNeeded()
        let currentSel = activeTextView?.selectedRange() ?? currentSelectedRange
        updateSelectionTooltipAnchor(for: currentSel)
        activeTextView?.needsDisplay = true
        if let tv = activeTextView, let window = tv.window {
            window.makeFirstResponder(tv)
        }
        return savedComment
    }

    @discardableResult
    public func copySingleSelectionComment(
        _ comment: SelectionComment,
        to pasteboard: NSPasteboard = .general
    ) -> String {
        let formatted = comment.formatForAgentPaste(
            documentTitle: documentTitle,
            fileURL: currentFileURL,
            workspaceFolderURL: workspaceFolderURL,
            documentText: markdownText
        )
        pasteboard.clearContents()
        pasteboard.setString(formatted, forType: .string)
        return formatted
    }

    @discardableResult
    public func copyDraftCommentImmediately(
        _ explicitText: String? = nil,
        to pasteboard: NSPasteboard = .general
    ) -> String? {
        guard let saved = addOrUpdateSelectionComment(explicitText) else { return nil }
        return copySingleSelectionComment(saved, to: pasteboard)
    }

    @discardableResult
    public func copyAllSelectionComments(to pasteboard: NSPasteboard = .general) -> String? {
        guard !selectionComments.isEmpty else { return nil }
        let formatted = SelectionComment.formatBatchForAgentPaste(
            selectionComments,
            documentTitle: documentTitle,
            fileURL: currentFileURL,
            workspaceFolderURL: workspaceFolderURL,
            documentText: markdownText
        )
        guard !formatted.isEmpty else { return nil }
        pasteboard.clearContents()
        pasteboard.setString(formatted, forType: .string)
        return formatted
    }

    public func removeSelectionComment(id: UUID) {
        if let removed = selectionComments.first(where: { $0.id == id }),
            activeCommentDraftRange == removed.range
        {
            activeCommentDraftRange = nil
            activeCommentDraftText = ""
        }
        selectionComments.removeAll { $0.id == id }
        if activeCommentID == id {
            activeCommentID = selectionComments.first?.id
        }
        autoSaveCompanionCommentsIfNeeded()
        updateSelectionTooltipAnchor()
        activeTextView?.needsDisplay = true
    }

    public func clearAllSelectionComments(deleteCompanionFile: Bool = true) {
        selectionComments.removeAll()
        activeCommentID = nil
        activeCommentDraftRange = nil
        activeCommentDraftText = ""
        if deleteCompanionFile {
            autoSaveCompanionCommentsIfNeeded()
        }
        updateSelectionTooltipAnchor(for: NSRange(location: currentSelectedRange.location, length: 0))
        activeTextView?.needsDisplay = true
    }

    public func selectComment(_ comment: SelectionComment) {
        let nsLen = (markdownText as NSString).length
        let loc = max(0, min(comment.range.location, nsLen))
        let len = max(0, min(comment.range.length, nsLen - loc))
        guard len > 0 else { return }
        let safeRange = NSRange(location: loc, length: len)

        activeCommentID = comment.id
        showCommentsSidebar = true
        currentSelectedRange = safeRange
        activeCommentDraftRange = safeRange
        activeCommentDraftText = comment.commentText
        if let tv = activeTextView {
            tv.setSelectedRange(safeRange)
            tv.scrollRangeToVisible(safeRange)
            tv.needsDisplay = true
        }
        updateSelectionTooltipAnchor(for: safeRange)
    }
}
