import AppKit
import SwiftUI

extension HybridMarkdownEditorRepresentable {

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var viewModel: EditorWorkspaceViewModel
        weak var textView: HybridMarkdownTextView?
        var isUpdatingFromTextView = false
        var isProgrammaticUpdate = false
        var isRestyling = false

        var lastTheme: EditorTheme?
        var lastTypography: EditorTypographySettings?
        var lastSourceMode: Bool?
        var lastPrettyMode: Bool?
        var lastTextAlignment: EditorTextAlignment?
        var lastFileURL: URL?
        var lastFocusMode: Bool?
        var lastActiveLineRange: NSRange?
        var lastContentWidth: CGFloat = 0

        /// Strong owner of the layout manager delegate (the layout manager holds it weakly).
        let softLineBreakLayoutDelegate = SoftLineBreakLayoutDelegate()
        /// Locations inside paragraphs the user edited. Each paragraph is rewrapped to the
        /// source line width when the selection leaves it.
        var reflowAnchors: [Int] = []
        var isApplyingReflow = false

        init(viewModel: EditorWorkspaceViewModel) {
            self.viewModel = viewModel
        }

        @objc func mediaImageDidLoad(_ notification: Notification) {
            guard let tv = textView else { return }
            restyle(textView: tv)
            tv.needsDisplay = true
        }

        @objc func scrollViewFrameDidChange(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView,
                  let tv = textView else { return }
            updateInsets(for: scrollView, textView: tv, theme: viewModel.theme)
            let newContentWidth = currentContentWidth(for: tv)
            if abs(newContentWidth - lastContentWidth) > 0.5 {
                restyle(textView: tv)
            }
        }

        func currentContentWidth(for textView: HybridMarkdownTextView) -> CGFloat {
            let totalWidth = textView.enclosingScrollView?.contentView.bounds.width
                ?? textView.enclosingScrollView?.bounds.width
                ?? textView.bounds.width
            let maxWrite = viewModel.typography.maxColumnWidth
            let horizontalPad = max(44.0, floor((totalWidth - maxWrite) / 2.0))
            let computed = totalWidth - horizontalPad * 2.0
            return computed > 200 ? computed : maxWrite
        }

        func updateInsets(for scrollView: NSScrollView, textView: HybridMarkdownTextView, theme: EditorTheme) {
            let viewportWidth = max(320.0, scrollView.contentView.bounds.width > 0 ? scrollView.contentView.bounds.width : scrollView.bounds.width)
            let maxWrite = viewModel.typography.maxColumnWidth
            let horizontalPad = max(44.0, floor((viewportWidth - maxWrite) / 2.0))
            let proseWidth = max(200.0, viewportWidth - horizontalPad * 2.0)
            let newInset = NSSize(width: horizontalPad, height: 42.0)
            if textView.textContainerInset != newInset {
                textView.textContainerInset = newInset
            }
            if abs(textView.proseColumnWidth - proseWidth) > 0.5 {
                textView.proseColumnWidth = proseWidth
            }

            // The canvas is exactly the viewport; tables wider than the column are laid out by
            // WideBlockTextContainer instead of widening the canvas.
            textView.minSize = NSSize(width: viewportWidth, height: 400)
            if abs(textView.frame.size.width - viewportWidth) > 0.5 {
                textView.frame.size.width = viewportWidth
            }
            if let tc = textView.textContainer {
                let targetContainerSize = NSSize(width: proseWidth, height: CGFloat.greatestFiniteMagnitude)
                if abs(tc.containerSize.width - targetContainerSize.width) > 0.5 {
                    tc.containerSize = targetContainerSize
                }
            }
            textView.refreshWideTableLayout()
        }

        public func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if !reflowAnchors.isEmpty, let replacement = replacementString {
                let delta = (replacement as NSString).length - affectedCharRange.length
                reflowAnchors = reflowAnchors.map { anchor in
                    anchor > affectedCharRange.location ? max(affectedCharRange.location, anchor + delta) : anchor
                }
            }
            return true
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, !isRestyling, let tv = textView else { return }
            isUpdatingFromTextView = true
            let currentText = tv.string
            let sel = tv.selectedRange()
            if !isApplyingReflow {
                reflowAnchors.append(sel.location)
                if reflowAnchors.count > 32 {
                    reflowAnchors.removeFirst(reflowAnchors.count - 32)
                }
                viewModel.isLiveKeystrokeInProgress = true
                viewModel.handleEditorTextEdited(currentText, selectedRange: sel)
                viewModel.isLiveKeystrokeInProgress = false
            } else {
                viewModel.withUndoMetadata(origin: .formattingAction, summary: "Reflow Paragraph") {
                    viewModel.handleEditorTextEdited(currentText, selectedRange: sel)
                }
            }
            restyle(textView: tv)
            tv.centerSelectionIfTypewriter()
            isUpdatingFromTextView = false
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate, !isRestyling, let tv = textView else { return }
            let sel = tv.selectedRange()
            let nsStr = tv.string as NSString
            let safeLoc = min(sel.location, nsStr.length)
            let activeLine = nsStr.lineRange(for: NSRange(location: safeLoc, length: 0))

            viewModel.updateSelectionStats(selectedRange: sel)

            if lastActiveLineRange != activeLine || viewModel.focusMode {
                lastActiveLineRange = activeLine
                restyle(textView: tv)
            }
            tv.centerSelectionIfTypewriter()

            if !reflowAnchors.isEmpty && viewModel.sourceLineWidth > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.reflowEditedParagraphsOutsideSelection()
                }
            }
        }

        /// Rewraps edited paragraphs to the source line width once the selection is outside
        /// them. Runs after the current edit and selection change complete.
        func reflowEditedParagraphsOutsideSelection() {
            guard let tv = textView, !reflowAnchors.isEmpty, !isApplyingReflow else { return }
            let width = viewModel.sourceLineWidth
            guard width > 0 else {
                reflowAnchors.removeAll()
                return
            }
            let text = tv.string
            let nsStr = text as NSString
            let sel = tv.selectedRange()
            let selLines = MarkdownSourceReflow.lineNumber(at: sel.location, in: nsStr)...MarkdownSourceReflow.lineNumber(at: NSMaxRange(sel), in: nsStr)
            let anchorLines = reflowAnchors.map { (anchor: $0, line: MarkdownSourceReflow.lineNumber(at: $0, in: nsStr)) }
            guard anchorLines.contains(where: { !selLines.contains($0.line) }) else { return }

            let spans = MarkdownSourceReflow.paragraphLineSpans(in: text)
            var keep: [Int] = []
            var targets: [ClosedRange<Int>] = []
            for entry in anchorLines {
                guard let span = spans.first(where: { $0.contains(entry.line) }) else { continue }
                if span.overlaps(selLines) {
                    keep.append(entry.anchor)
                } else if !targets.contains(span) {
                    targets.append(span)
                }
            }
            reflowAnchors = keep
            guard !targets.isEmpty else { return }

            isApplyingReflow = true
            tv.breakUndoCoalescing()
            // Bottom-up, so line numbers of the remaining paragraphs stay valid.
            for span in targets.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                let current = tv.string
                guard let edit = MarkdownSourceReflow.reflowParagraph(in: current, line: span.lowerBound, width: width),
                      (current as NSString).substring(with: edit.range) != edit.replacement else { continue }
                var newSel = tv.selectedRange()
                if newSel.location >= NSMaxRange(edit.range) {
                    newSel.location += (edit.replacement as NSString).length - edit.range.length
                }
                if tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                    tv.replaceCharacters(in: edit.range, with: edit.replacement)
                    tv.didChangeText()
                    tv.undoManager?.setActionName("Reflow Paragraph")
                    tv.setSelectedRange(newSel)
                }
            }
            tv.breakUndoCoalescing()
            isApplyingReflow = false
        }

        func restyle(textView: HybridMarkdownTextView) {
            guard !isRestyling, let storage = textView.textStorage else { return }
            isRestyling = true
            let sel = textView.selectedRange()
            let contentWidth = currentContentWidth(for: textView)
            let baseDir = viewModel.currentFileURL?.deletingLastPathComponent() ?? viewModel.workspaceFolderURL

            let analysis = MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: viewModel.theme,
                typography: viewModel.typography,
                sourceCodeMode: viewModel.sourceCodeMode,
                focusMode: viewModel.focusMode,
                selectedRange: sel,
                containerWidth: contentWidth,
                prettyMode: viewModel.prettyModeEnabled,
                baseDirectoryURL: baseDir,
                textAlignment: viewModel.textAlignment.nsAlignment
            )

            // Clear any spellchecker squiggles on code/math/table decorations
            if let lm = textView.layoutManager {
                let fullRange = NSRange(location: 0, length: (storage.string as NSString).length)
                if !viewModel.spellCheckEnabled {
                    lm.removeTemporaryAttribute(.spellingState, forCharacterRange: fullRange)
                } else {
                    for dec in analysis.decorations {
                        lm.removeTemporaryAttribute(.spellingState, forCharacterRange: dec.lineRange)
                    }
                }
            }

            if let scrollView = textView.enclosingScrollView {
                updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)
            }

            textView.lineDecorations = analysis.decorations
            textView.needsDisplay = true
            lastTheme = viewModel.theme
            lastTypography = viewModel.typography
            lastSourceMode = viewModel.sourceCodeMode
            lastPrettyMode = viewModel.prettyModeEnabled
            lastTextAlignment = viewModel.textAlignment
            lastFileURL = viewModel.currentFileURL
            lastFocusMode = viewModel.focusMode
            lastContentWidth = contentWidth

            let currentHeadings = analysis.headings
            if viewModel.headings != currentHeadings {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.headings = currentHeadings
                }
            }

            // Update active heading in outline based on cursor position
            let cursorLoc = sel.location
            let activeHeading = currentHeadings.last(where: { $0.characterLocation <= cursorLoc })
            if viewModel.activeHeadingID != activeHeading?.id {
                DispatchQueue.main.async { [weak self] in
                    self?.viewModel.activeHeadingID = activeHeading?.id
                }
            }

            isRestyling = false
        }
    }
}
