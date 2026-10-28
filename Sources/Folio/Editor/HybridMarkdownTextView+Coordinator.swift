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
        var lastSpellCheckEnabled: Bool?
        var lastActiveLineRange: NSRange?
        var lastKnownTextHash: Int?
        var lastContentWidth: CGFloat = 0
        var lastViewportWidth: CGFloat = 0
        var lastMaxColumnWidth: CGFloat = 0
        var hasPerformedInitialScroll = false
        var pendingResizeRestyleWorkItem: DispatchWorkItem?
        var scheduler = EditorScheduler.live
        /// The last Markdown restyle, for restyling only what the next edit can affect.
        var styleRecord: MarkdownStyleRecord?
        /// Characters edited since the last restyle.
        var pendingTextEdit: MarkdownTextEdit?
        /// Why the last restyle styled the whole document; nil after an incremental restyle.
        var lastFullRestyleReason: MarkdownFullRestyleReason?
        /// A text change arrived during input-method composition and was not restyled yet.
        var isRestyleDeferredForMarkedText = false

        let softLineBreakLayoutDelegate = SoftLineBreakLayoutDelegate()
        var reflowAnchors: [Int] = []
        var isApplyingReflow = false
        let perf = EditorPerfRecorder()

        init(viewModel: EditorWorkspaceViewModel) {
            self.viewModel = viewModel
        }

        @objc func mediaImageDidLoad(_ notification: Notification) {
            guard let tv = textView else { return }
            restyle(textView: tv)
            tv.needsDisplay = true
        }

        /// Restyles a LaTeX document after its master, inputs, or bibliography were reloaded.
        @objc func latexProjectDidUpdate(_ notification: Notification) {
            guard let tv = textView, viewModel.isCurrentDocumentLaTeX else { return }
            restyle(textView: tv)
            tv.needsDisplay = true
        }

        @objc func scrollViewFrameDidChange(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView,
                let tv = textView
            else { return }
            updateInsets(for: scrollView, textView: tv, theme: viewModel.theme)
            let newContentWidth = currentContentWidth(for: tv)
            if abs(newContentWidth - lastContentWidth) > 0.5 {
                scheduleResizeRestyle(for: tv)
            }
            tv.scheduleHTMLBlockOverlaySync()
            viewModel.refreshTooltipAnchorOnViewportChangeIfNeeded()
        }

        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            textView?.scheduleHTMLBlockOverlaySync()
            viewModel.refreshTooltipAnchorOnViewportChangeIfNeeded()
        }

        func scheduleResizeRestyle(for textView: HybridMarkdownTextView) {
            pendingResizeRestyleWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self = self, let tv = textView else { return }
                let width = self.currentContentWidth(for: tv)
                if abs(width - self.lastContentWidth) > 0.5 {
                    self.restyle(textView: tv)
                }
            }
            pendingResizeRestyleWorkItem = item
            scheduler.schedule(0.06, item)
        }

        func currentContentWidth(for textView: HybridMarkdownTextView) -> CGFloat {
            let totalWidth =
                textView.enclosingScrollView?.contentView.bounds.width
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
            guard abs(viewportWidth - lastViewportWidth) > 0.5 || abs(maxWrite - lastMaxColumnWidth) > 0.5 else {
                return
            }
            lastViewportWidth = viewportWidth
            lastMaxColumnWidth = maxWrite

            let horizontalPad = max(44.0, floor((viewportWidth - maxWrite) / 2.0))
            let proseWidth = max(200.0, viewportWidth - horizontalPad * 2.0)
            var geometryChanged = false
            if textView.textContainerInset.height != 42.0 {
                textView.textContainerInset = NSSize(width: 44.0, height: 42.0)
                geometryChanged = true
            }
            if textView.horizontalColumnInset != horizontalPad {
                textView.horizontalColumnInset = horizontalPad
            }
            if abs(textView.proseColumnWidth - proseWidth) > 0.5 {
                textView.proseColumnWidth = proseWidth
                geometryChanged = true
            }

            // The canvas is exactly the viewport; tables wider than the column are laid out by
            // WideBlockTextContainer instead of widening the canvas.
            if abs(textView.frame.size.width - viewportWidth) > 0.5 {
                textView.frame.size.width = viewportWidth
                geometryChanged = true
            }
            if let tc = textView.textContainer {
                let targetContainerSize = NSSize(width: proseWidth, height: CGFloat.greatestFiniteMagnitude)
                if abs(tc.containerSize.width - targetContainerSize.width) > 0.5 {
                    tc.containerSize = targetContainerSize
                    geometryChanged = true
                }
            }
            if geometryChanged {
                textView.refreshWideTableLayout()
            }
            if !hasPerformedInitialScroll && scrollView.bounds.height > 0 {
                hasPerformedInitialScroll = true
                if viewModel.currentSelectedRange.location == 0 {
                    scrollView.contentView.scroll(to: .zero)
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                } else {
                    textView.scrollRangeToVisible(viewModel.currentSelectedRange)
                }
            }
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
            lastKnownTextHash = currentText.hashValue
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
            if tv.hasMarkedText() {
                // Restyling during composition would reset the marked text attributes.
                isRestyleDeferredForMarkedText = true
            } else {
                isRestyleDeferredForMarkedText = false
                restyle(textView: tv, incremental: true)
            }
            tv.centerSelectionIfTypewriter()
            isUpdatingFromTextView = false
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate, !isRestyling, !isUpdatingFromTextView, let tv = textView else { return }
            let currentText = tv.string
            if let lastHash = lastKnownTextHash, currentText.hashValue != lastHash {
                return
            }
            let sel = tv.selectedRange()
            let nsStr = currentText as NSString
            let safeLoc = min(sel.location, nsStr.length)
            let activeLine = nsStr.lineRange(for: NSRange(location: safeLoc, length: 0))

            viewModel.handleTextViewSelectionChange(in: tv, selectedRange: sel)

            let needsRestyle = lastActiveLineRange != activeLine || viewModel.focusMode || isRestyleDeferredForMarkedText
            if needsRestyle && !tv.hasMarkedText() {
                lastActiveLineRange = activeLine
                isRestyleDeferredForMarkedText = false
                restyle(textView: tv, incremental: true)
            }
            tv.centerSelectionIfTypewriter()

            if !reflowAnchors.isEmpty && viewModel.sourceLineWidth > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.reflowEditedParagraphsOutsideSelection()
                }
            }
        }

        /// Restyles the document. With `incremental`, restyles only the blocks that the edits and
        /// the selection change since the last restyle can affect, when that equals a full restyle.
        func restyle(textView: HybridMarkdownTextView, incremental: Bool = false) {
            pendingResizeRestyleWorkItem?.cancel()
            pendingResizeRestyleWorkItem = nil
            guard !isRestyling, let storage = textView.textStorage else { return }
            isRestyling = true
            perf.beginRestylePass()
            EditorPerfScope.bind(perf) {
                EditorPerfPhase.restyle.measure {
                    performRestyle(textView: textView, storage: storage, incremental: incremental)
                }
            }
            perf.endRestylePass(documentLength: storage.length)
            isRestyling = false
        }

        private func performRestyle(textView: HybridMarkdownTextView, storage: NSTextStorage, incremental: Bool) {
            let sel = textView.selectedRange()
            let parameters = styleParameters(for: textView)
            let contentWidth = parameters.containerWidth
            let edit = pendingTextEdit
            pendingTextEdit = nil

            let result = styleResult(storage: storage, parameters: parameters, selectedRange: sel, edit: edit, incremental: incremental)
            styleRecord = result.record
            let analysis = result.analysis
            clearSpellingMarks(textView: textView, storage: storage, decorations: analysis.decorations, restyledRanges: result.restyledRanges)

            if let scrollView = textView.enclosingScrollView {
                updateInsets(for: scrollView, textView: textView, theme: viewModel.theme)
            }

            textView.lineDecorations = analysis.decorations
            textView.needsDisplay = true
            let nsStr = storage.string as NSString
            lastActiveLineRange = nsStr.lineRange(for: NSRange(location: min(sel.location, nsStr.length), length: 0))
            lastTheme = viewModel.theme
            lastTypography = viewModel.typography
            lastSourceMode = viewModel.sourceCodeMode
            lastPrettyMode = viewModel.prettyModeEnabled
            lastTextAlignment = viewModel.textAlignment
            lastFileURL = viewModel.currentFileURL
            lastFocusMode = viewModel.focusMode
            lastContentWidth = contentWidth

            let currentHeadings = analysis.headings
            let cursorLoc = sel.location
            let activeHeadingID = currentHeadings.last(where: { $0.characterLocation <= cursorLoc })?.id
            let headingsChanged = viewModel.headings != currentHeadings
            let activeHeadingChanged = viewModel.activeHeadingID != activeHeadingID
            if headingsChanged || activeHeadingChanged {
                if isUpdatingFromTextView {
                    if headingsChanged { viewModel.headings = currentHeadings }
                    if activeHeadingChanged { viewModel.activeHeadingID = activeHeadingID }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.viewModel.headings != currentHeadings {
                            self.viewModel.headings = currentHeadings
                        }
                        if self.viewModel.activeHeadingID != activeHeadingID {
                            self.viewModel.activeHeadingID = activeHeadingID
                        }
                    }
                }
            }
        }
    }
}
