import AppKit
import Combine
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
        if !isRestoringState && autoSaveDelay <= 0 {
            userDefaults.set(selectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        }
        let updatedStats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
        if stats != updatedStats {
            stats = updatedStats
        }
    }

    public func updateSelectionStats(selectedRange: NSRange) {
        if selectedRange != currentSelectedRange && !isLiveKeystrokeInProgress {
            canCoalesceLiveTyping = false
        }
        currentSelectedRange = selectedRange
        if !isRestoringState && autoSaveDelay <= 0 {
            userDefaults.set(selectedRange.location, forKey: Self.selectedCursorLocationDefaultsKey)
        }
        if selectedRange.length == 0 && stats.selectedCharacters == 0 {
            return
        }
        let updatedStats = DocumentStats.compute(for: markdownText, selectedRange: selectedRange)
        if stats != updatedStats {
            stats = updatedStats
        }
    }

    // MARK: - Task Checkbox Toggling
    public func toggleTaskCheckbox(at boxCharacterLocation: Int) {
        let nsStr = markdownText as NSString
        let boxRange = NSRange(location: boxCharacterLocation, length: 3)
        guard boxCharacterLocation >= 0, NSMaxRange(boxRange) <= nsStr.length else { return }

        let currentBox = nsStr.substring(with: boxRange)
        let replacement: String
        if currentBox.lowercased() == "[x]" {
            replacement = "[ ]"
        } else if currentBox == "[ ]" {
            replacement = "[x]"
        } else {
            return
        }

        withUndoMetadata(origin: .formattingAction, summary: "Toggle Task Checkbox") {
            if let tv = activeTextView, tv.shouldChangeText(in: boxRange, replacementString: replacement) {
                tv.replaceCharacters(in: boxRange, with: replacement)
                tv.didChangeText()
            } else {
                markdownText = nsStr.replacingCharacters(in: boxRange, with: replacement)
            }
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
                  nsStr.substring(with: edit.range) != edit.replacement else { return }
            let newLocation = edit.range.location + MarkdownSourceReflow.mapLocation(
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
        withUndoMetadata(origin: .formattingAction, summary: level == 0 ? "Convert to Paragraph" : "Heading \(level)") {
            guard let tv = activeTextView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let lineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
            var contentRange = lineRange
            while contentRange.length > 0 {
                let ch = nsStr.character(at: contentRange.location + contentRange.length - 1)
                if ch == 10 || ch == 13 { contentRange.length -= 1 } else { break }
            }
            let lineText = nsStr.substring(with: contentRange)
            let stripped = lineText.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)

            let replacement: String
            if level == 0 {
                replacement = stripped
            } else {
                let hashes = String(repeating: "#", count: min(6, max(1, level)))
                replacement = "\(hashes) \(stripped.isEmpty ? "Heading \(level)" : stripped)"
            }

            if tv.shouldChangeText(in: contentRange, replacementString: replacement) {
                tv.replaceCharacters(in: contentRange, with: replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: contentRange.location + (replacement as NSString).length, length: 0))
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
