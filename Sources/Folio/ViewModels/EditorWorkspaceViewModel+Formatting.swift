import AppKit
import Combine
import FolioEngineFFI
import Foundation
import SwiftUI

extension EditorWorkspaceViewModel {

    // MARK: - Directory Expansion State
    public func isDirectoryExpanded(_ url: URL) -> Bool {
        !collapsedDirectoryPaths.contains(url.standardizedFileURL.path)
    }

    public func setDirectoryExpanded(_ expanded: Bool, for url: URL) {
        let key = url.standardizedFileURL.path
        if expanded {
            collapsedDirectoryPaths.remove(key)
        } else {
            collapsedDirectoryPaths.insert(key)
        }
    }

    public func toggleDirectoryExpanded(_ url: URL) {
        let key = url.standardizedFileURL.path
        if collapsedDirectoryPaths.contains(key) {
            collapsedDirectoryPaths.remove(key)
        } else {
            collapsedDirectoryPaths.insert(key)
        }
    }

    // MARK: - Document Title
    public var documentTitle: String {
        if let url = currentFileURL {
            return url.lastPathComponent
        }
        let ext = isCurrentDocumentLaTeX ? "tex" : (isCurrentDocumentBibTeX ? "bib" : "md")
        if let firstH1 = headings.first(where: { $0.level == 1 }) {
            return "\(firstH1.title).\(ext)"
        }
        return "Untitled.\(ext)"
    }

    // MARK: - Live Editor Updates
    public func handleEditorTextEdited(_ newText: String, selectedRange: NSRange) {
        let previousSel = currentSelectedRange
        currentSelectedRange = selectedRange
        if markdownText != newText {
            let oldText = markdownText
            clearExternalUpdateHighlights()
            isApplyingInternalStateChange = true
            markdownText = newText
            isApplyingInternalStateChange = false

            let allowCoalesce = canCoalesceLiveTyping
            recordUndoStep(
                from: oldText,
                to: newText,
                previousSelection: previousSel,
                newSelection: selectedRange,
                origin: pendingEditOrigin,
                summary: pendingEditSummary,
                allowCoalescing: allowCoalesce
            )
            pendingEditOrigin = .userTyping
            pendingEditSummary = nil
            reconcileSelectionComments(from: oldText, to: newText)

            if activeTextView == nil {
                let analysis = MarkdownLiveStyler.applyStyles(
                    to: NSTextStorage(string: newText),
                    theme: theme,
                    typography: typography,
                    sourceCodeMode: sourceCodeMode,
                    focusMode: focusMode,
                    selectedRange: selectedRange,
                    baseDirectoryURL: currentFileURL?.deletingLastPathComponent() ?? workspaceFolderURL,
                    fileURL: currentFileURL
                )
                headings = analysis.headings
            }
            scheduleAutoSave()
        }
        if !isRestoringState && (!isLiveKeystrokeInProgress || autoSaveDelay <= 0) {
            setSessionValue(selectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        }
        let updatedStats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
        if stats != updatedStats {
            stats = updatedStats
        }
        updateSelectionTooltipAnchor(for: selectedRange)
    }

    // MARK: - Task Checkbox Toggling
    public func toggleTaskCheckbox(at boxCharacterLocation: Int) {
        guard !isCurrentDocumentLaTeX && !isCurrentDocumentBibTeX else { return }
        let sourceLength = ((activeTextView?.string ?? markdownText) as NSString).length
        guard boxCharacterLocation >= 0, boxCharacterLocation < sourceLength else { return }

        applyEngineSpanEdit(
            origin: .formattingAction,
            summary: "Toggle Task Checkbox",
            preserveExistingSelection: true
        ) { cStr, _, _ in
            ot_engine_edit_task_checkbox_utf16(cStr, boxCharacterLocation, 0)
        }
    }

    public func toggleTaskCheckboxAtSelection() {
        guard !isCurrentDocumentLaTeX && !isCurrentDocumentBibTeX else { return }
        applyEngineSpanEdit(origin: .formattingAction, summary: "Toggle Task Checkbox") { cStr, loc, len in
            ot_engine_edit_task_checkbox_utf16(cStr, loc, len)
        }
    }

    // MARK: - Navigation
    public func scrollToHeading(_ heading: OutlineHeading) {
        pendingScrollToCharacterLocation = heading.characterLocation
        activeHeadingID = heading.id
    }

    public func jumpToSearchMatch(_ match: WorkspaceSearchMatch) {
        if currentFileURL != match.fileURL {
            openFile(at: match.fileURL)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pendingScrollToCharacterLocation = match.matchRangeInFile.location
        }
    }

    // MARK: - Formatting & Markdown Insertion Commands
    public func applyInlineFormatting(prefix: String, suffix: String, placeholder: String) {
        let resolved = resolvedInlineDelimiters(prefix: prefix, suffix: suffix, placeholder: placeholder)
        if !isCurrentDocumentLaTeX && !isCurrentDocumentBibTeX && !resolved.prefix.isEmpty && resolved.prefix == resolved.suffix {
            let delimiter = resolved.prefix
            applyEngineSpanEdit(origin: .formattingAction, summary: "Inline Formatting") { cStr, loc, len in
                delimiter.withCString { delimPtr in
                    ot_engine_edit_symmetric_delimiter_utf16(cStr, loc, len, delimPtr)
                }
            }
            return
        }

        withUndoMetadata(origin: .formattingAction, summary: "Inline Formatting") {
            guard let tv = activeTextView else {
                markdownText += "\(resolved.prefix)\(resolved.placeholder)\(resolved.suffix)"
                return
            }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let selectedText = sel.length > 0 ? nsStr.substring(with: sel) : resolved.placeholder
            let replacement = "\(resolved.prefix)\(selectedText)\(resolved.suffix)"

            if tv.shouldChangeText(in: sel, replacementString: replacement) {
                tv.replaceCharacters(in: sel, with: replacement)
                tv.didChangeText()
                let innerRange = NSRange(
                    location: sel.location + (resolved.prefix as NSString).length,
                    length: (selectedText as NSString).length
                )
                tv.setSelectedRange(innerRange)
                updateTopUndoNewSelection(innerRange)
            }
        }
    }

    /// Width for explicit reflow commands: the source line width, or the default when auto-wrap is off.
    public var effectiveReflowWidth: Int {
        sourceLineWidth > 0 ? sourceLineWidth : MarkdownSourceReflow.defaultWidth
    }

    /// Hard-wraps the paragraph at the cursor to `effectiveReflowWidth` columns.
    public func reflowCurrentParagraph() {
        guard !isCurrentDocumentLaTeX && !isCurrentDocumentBibTeX else { return }
        withUndoMetadata(origin: .formattingAction, summary: "Reflow Paragraph") {
            guard let tv = activeTextView else { return }
            let text = tv.string
            let nsStr = text as NSString
            let sel = tv.selectedRange()
            let line = MarkdownSourceReflow.lineNumber(at: sel.location, in: nsStr)
            guard let edit = MarkdownSourceReflow.reflowParagraph(in: text, line: line, width: effectiveReflowWidth),
                nsStr.substring(with: edit.range) != edit.replacement
            else { return }
            let newLocation =
                edit.range.location
                + MarkdownSourceReflow.mapLocation(
                    sel.location, in: nsStr, oldRange: edit.range, to: edit.replacement as NSString
                )
            tv.breakUndoCoalescing()
            if tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                tv.replaceCharacters(in: edit.range, with: edit.replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: newLocation, length: 0))
            }
        }
    }

    /// Hard-wraps every paragraph in the document to `effectiveReflowWidth` columns.
    public func reflowDocument() {
        guard !isCurrentDocumentLaTeX && !isCurrentDocumentBibTeX else { return }
        withUndoMetadata(origin: .formattingAction, summary: "Reflow Document") {
            guard let tv = activeTextView else {
                let reflowed = MarkdownSourceReflow.reflowDocument(markdownText, width: effectiveReflowWidth)
                if reflowed != markdownText {
                    markdownText = reflowed
                }
                return
            }
            let text = tv.string
            let nsStr = text as NSString
            let reflowed = MarkdownSourceReflow.reflowDocument(text, width: effectiveReflowWidth)
            guard reflowed != text else { return }
            let fullRange = NSRange(location: 0, length: nsStr.length)
            let newLocation = MarkdownSourceReflow.mapLocation(
                tv.selectedRange().location, in: nsStr, oldRange: fullRange, to: reflowed as NSString
            )
            tv.breakUndoCoalescing()
            if tv.shouldChangeText(in: fullRange, replacementString: reflowed) {
                tv.replaceCharacters(in: fullRange, with: reflowed)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: newLocation, length: 0))
            }
        }
    }

    public func setHeadingLevel(_ level: Int) {
        if isCurrentDocumentLaTeX {
            setLaTeXHeadingLevel(level)
            return
        }
        guard !isCurrentDocumentBibTeX else { return }
        let clampedLevel = UInt8(clamping: max(0, min(6, level)))
        let summary = clampedLevel == 0 ? "Convert to Paragraph" : "Heading \(clampedLevel)"
        applyEngineSpanEdit(origin: .formattingAction, summary: summary) { cStr, loc, len in
            ot_engine_edit_heading_level_utf16(cStr, loc, len, clampedLevel, false)
        }
    }

    private func applyEngineSpanEdit(
        origin: UndoEntryOrigin,
        summary: String,
        preserveExistingSelection: Bool = false,
        build: (UnsafePointer<CChar>, Int, Int) -> OTSpanEditResult
    ) {
        let sourceText = activeTextView?.string ?? markdownText
        let nsStr = sourceText as NSString
        let rawSelection = activeTextView?.selectedRange() ?? currentSelectedRange
        let safeLoc = max(0, min(rawSelection.location, nsStr.length))
        let safeLen = max(0, min(rawSelection.length, nsStr.length - safeLoc))
        let sel = NSRange(location: safeLoc, length: safeLen)

        let edit = sourceText.withCString { cStr in
            build(cStr, sel.location, sel.length)
        }
        defer {
            ot_engine_free_span_edit(edit)
        }

        guard let replacementPtr = edit.replacement else { return }
        let replacement = String(cString: replacementPtr)
        let replaceRange = NSRange(location: edit.replace_loc, length: edit.replace_len)
        guard replaceRange.location >= 0, NSMaxRange(replaceRange) <= nsStr.length else { return }

        let newSelection: NSRange
        if preserveExistingSelection {
            let delta = (replacement as NSString).length - replaceRange.length
            let adjustedLoc = sel.location >= NSMaxRange(replaceRange) ? max(0, sel.location + delta) : sel.location
            newSelection = NSRange(location: adjustedLoc, length: sel.length)
        } else {
            newSelection = NSRange(location: edit.select_loc, length: edit.select_len)
        }

        if replaceRange.length == 0 && replacement.isEmpty {
            if newSelection != sel {
                if let tv = activeTextView {
                    tv.setSelectedRange(newSelection)
                } else {
                    currentSelectedRange = newSelection
                }
            }
            return
        }

        withUndoMetadata(origin: origin, summary: summary) {
            if let tv = activeTextView {
                let tvNS = tv.string as NSString
                if tvNS.substring(with: replaceRange) == replacement {
                    if tv.selectedRange() != newSelection {
                        tv.setSelectedRange(newSelection)
                    }
                } else if tv.shouldChangeText(in: replaceRange, replacementString: replacement) {
                    tv.replaceCharacters(in: replaceRange, with: replacement)
                    tv.didChangeText()
                    if tv.selectedRange() != newSelection {
                        tv.setSelectedRange(newSelection)
                    }
                    updateTopUndoNewSelection(newSelection)
                }
            } else {
                let updated = nsStr.replacingCharacters(in: replaceRange, with: replacement)
                if markdownText != updated {
                    markdownText = updated
                }
                currentSelectedRange = newSelection
                updateTopUndoNewSelection(newSelection)
            }
        }
    }

    public func insertBlockquote() {
        if isCurrentDocumentLaTeX {
            insertSnippetAtCursor("\n\\begin{quote}\n\n\\end{quote}\n", cursorOffsetFromStart: 15, summary: "Insert Quote")
            return
        }
        prefixCurrentLine(with: "> ", summary: "Insert Blockquote")
    }

    public func insertUnorderedList() {
        if isCurrentDocumentLaTeX {
            insertSnippetAtCursor("\n\\begin{itemize}\n  \\item \n\\end{itemize}\n", cursorOffsetFromStart: 25, summary: "Insert Bullet List")
            return
        }
        prefixCurrentLine(with: "- ", summary: "Insert Bullet List")
    }

    public func insertOrderedList() {
        if isCurrentDocumentLaTeX {
            insertSnippetAtCursor("\n\\begin{enumerate}\n  \\item \n\\end{enumerate}\n", cursorOffsetFromStart: 27, summary: "Insert Numbered List")
            return
        }
        prefixCurrentLine(with: "1. ", summary: "Insert Numbered List")
    }

    public func insertTaskList() {
        prefixCurrentLine(with: "- [ ] ", summary: "Insert Task List")
    }

    func prefixCurrentLine(with prefix: String, summary: String = "Format Line") {
        withUndoMetadata(origin: .formattingAction, summary: summary) {
            guard let tv = activeTextView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if tv.shouldChangeText(in: insertRange, replacementString: prefix) {
                tv.replaceCharacters(in: insertRange, with: prefix)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: 0))
            }
        }
    }

    func insertSnippetAtCursor(_ snippet: String, cursorOffsetFromStart: Int, summary: String = "Insert Snippet") {
        withUndoMetadata(origin: .formattingAction, summary: summary) {
            guard let tv = activeTextView else {
                markdownText += snippet
                return
            }
            let sel = tv.selectedRange()
            if tv.shouldChangeText(in: sel, replacementString: snippet) {
                tv.replaceCharacters(in: sel, with: snippet)
                tv.didChangeText()
                let newCursor = min((tv.string as NSString).length, sel.location + cursorOffsetFromStart)
                tv.setSelectedRange(NSRange(location: newCursor, length: 0))
            }
        }
    }
}
