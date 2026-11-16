import AppKit
import SwiftUI

@MainActor
public final class MarkdownEditorCoordinator: NSObject, NSTextViewDelegate, HybridMarkdownCoordinatorDelegate {

    package struct SyncedStyleConfiguration: Equatable {
        var theme: EditorTheme
        var typography: EditorTypographySettings
        var sourceCodeMode: Bool
        var prettyMode: Bool
        var textAlignment: EditorTextAlignment
        var fileURL: URL?
        var focusMode: Bool

        @MainActor
        init(viewModel: EditorWorkspaceViewModel) {
            self.theme = viewModel.theme
            self.typography = viewModel.typography
            self.sourceCodeMode = viewModel.sourceCodeMode
            self.prettyMode = viewModel.prettyModeEnabled
            self.textAlignment = viewModel.textAlignment
            self.fileURL = viewModel.currentFileURL
            self.focusMode = viewModel.focusMode
        }
    }

    package var viewModel: EditorWorkspaceViewModel
    package weak var textView: HybridMarkdownTextView?
    package var isUpdatingFromTextView = false
    package var isProgrammaticUpdate = false
    package var isRestyling = false

    package var lastSyncedConfiguration: SyncedStyleConfiguration?
    package var lastSpellCheckEnabled: Bool?
    package var lastActiveLineRange: NSRange?
    package var storageCharacterEditGeneration: UInt64 = 0
    package var syncedCharacterEditGeneration: UInt64 = 0
    package var lastKnownTextHash: Int? {
        didSet {
            syncedCharacterEditGeneration = storageCharacterEditGeneration
        }
    }
    package var lastContentWidth: CGFloat = 0
    package var lastViewportWidth: CGFloat = 0
    package var lastMaxColumnWidth: CGFloat = 0
    package var hasPerformedInitialScroll = false
    package var pendingResizeRestyleWorkItem: DispatchWorkItem?
    package var scheduler = EditorScheduler.live
    /// The last Markdown restyle, for restyling only what the next edit can affect.
    package var styleRecord: MarkdownStyleRecord?
    /// Characters edited since the last restyle.
    package var pendingTextEdit: MarkdownTextEdit?
    /// Why the last restyle styled the whole document, or nil after an incremental restyle.
    package var lastFullRestyleReason: MarkdownFullRestyleReason?
    /// A text change arrived during input-method composition and was not restyled yet.
    package var isRestyleDeferredForMarkedText = false

    package let softLineBreakLayoutDelegate = SoftLineBreakLayoutDelegate()
    package var reflowAnchors: [Int] = []
    package var isApplyingReflow = false
    package let perf = EditorPerfRecorder()

    /// Snapshot of the work this editor has done since it was created.
    var perfCounters: EditorPerfCounters {
        perf.counters
    }

    package init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    package func clearReflowAnchors() {
        reflowAnchors.removeAll()
    }

    func observeTextStorage(_ storage: NSTextStorage) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordTextEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage
        )
    }

    @objc func recordTextEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
            storage.editedRange.location != NSNotFound
        else { return }

        if isRestyling && storage.editedMask.contains(.editedAttributes) {
            perf.recordAttributeEdit(length: storage.editedRange.length)
        }

        guard storage.editedMask.contains(.editedCharacters) else { return }
        storageCharacterEditGeneration &+= 1
        if isProgrammaticUpdate {
            syncedCharacterEditGeneration = storageCharacterEditGeneration
        }
        let range = storage.editedRange
        let delta = storage.changeInLength
        if var edit = pendingTextEdit {
            edit.merge(editedRange: range, changeInLength: delta)
            pendingTextEdit = edit
        } else {
            pendingTextEdit = MarkdownTextEdit(range: range, changeInLength: delta)
        }
        LaTeXBlockStyleCache.noteTextEdit(for: storage, editedRange: range, changeInLength: delta)
    }

    @objc func mediaImageDidLoad(_ notification: Notification) {
        guard let tv = textView else { return }
        if viewModel.isCurrentDocumentLaTeX, let storage = tv.textStorage {
            // A cached LaTeX figure block reserved the height of the image before it loaded.
            LaTeXBlockStyleCache.invalidate(for: storage)
        }
        let hasRenderedMedia = tv.lineDecorations.contains { decoration in
            switch decoration.kind {
            case .imageRendered, .mermaidBlockRendered, .svgBlockRendered:
                return true
            default:
                return false
            }
        }
        guard hasRenderedMedia else { return }
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
        scheduleResizeRestyleIfWidthChanged(for: tv)
        tv.scheduleHTMLBlockOverlaySync()
        viewModel.refreshTooltipAnchorOnViewportChangeIfNeeded()
    }

    /// A legacy vertical scroller that appears or hides resizes the clip view while the
    /// scroll view frame stays the same.
    @objc func clipViewFrameDidChange(_ notification: Notification) {
        guard let scrollView = (notification.object as? NSClipView)?.enclosingScrollView,
            let tv = textView
        else { return }
        updateInsets(for: scrollView, textView: tv, theme: viewModel.theme)
        scheduleResizeRestyleIfWidthChanged(for: tv)
        tv.scheduleHTMLBlockOverlaySync()
    }

    @objc func clipViewBoundsDidChange(_ notification: Notification) {
        textView?.scheduleHTMLBlockOverlaySync()
        viewModel.refreshTooltipAnchorOnViewportChangeIfNeeded()
    }

    private func scheduleResizeRestyleIfWidthChanged(for textView: HybridMarkdownTextView) {
        if abs(currentContentWidth(for: textView) - lastContentWidth) > 0.5 {
            scheduleResizeRestyle(for: textView)
        }
    }

    func scheduleResizeRestyle(for textView: HybridMarkdownTextView) {
        pendingResizeRestyleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak textView] in
            guard let self = self else { return }
            self.pendingResizeRestyleWorkItem = nil
            guard let tv = textView else { return }
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

        // The canvas is exactly the viewport, while tables wider than the column are laid out by
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
        syncedCharacterEditGeneration = storageCharacterEditGeneration
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
        // NSTextStorage updates selection and posts didChangeSelectionNotification before NSTextView
        // posts didChangeNotification, so skip selection notifications while character edits are unsynced.
        guard !isProgrammaticUpdate,
            !isRestyling,
            !isUpdatingFromTextView,
            storageCharacterEditGeneration == syncedCharacterEditGeneration,
            let tv = textView
        else { return }
        let sel = tv.selectedRange()
        let nsStr = (tv.textStorage?.string ?? tv.string) as NSString
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

    /// Style parameters for the current view model settings and text view width.
    package func styleParameters(for textView: HybridMarkdownTextView) -> MarkdownStyleParameters {
        MarkdownStyleParameters(
            theme: viewModel.theme,
            typography: viewModel.typography,
            sourceCodeMode: viewModel.sourceCodeMode,
            focusMode: viewModel.focusMode,
            containerWidth: currentContentWidth(for: textView),
            prettyMode: viewModel.prettyModeEnabled,
            baseDirectoryURL: viewModel.currentFileURL?.deletingLastPathComponent() ?? viewModel.workspaceFolderURL,
            textAlignment: viewModel.textAlignment.nsAlignment,
            fileURL: viewModel.currentFileURL
        )
    }

    /// Restyles after input-method composition ends, if a text change was deferred during it.
    package func restyleAfterMarkedText(textView: HybridMarkdownTextView) {
        guard isRestyleDeferredForMarkedText, !textView.hasMarkedText() else { return }
        isRestyleDeferredForMarkedText = false
        restyle(textView: textView, incremental: true)
    }

    /// Restyles the document. With `incremental`, restyles only the blocks that the edits and
    /// the selection change since the last restyle can affect, when that equals a full restyle.
    package func restyle(textView: HybridMarkdownTextView, incremental: Bool = false) {
        pendingResizeRestyleWorkItem?.cancel()
        pendingResizeRestyleWorkItem = nil
        guard !isRestyling, let storage = textView.textStorage else { return }
        if !incremental {
            syncedCharacterEditGeneration = storageCharacterEditGeneration
        }
        isRestyling = true
        perf.beginRestylePass()
        EditorPerfScope.bind(perf) {
            EditorPerfPhase.restyle.measure {
                performRestyle(textView: textView, storage: storage, incremental: incremental)
            }
        }
        perf.endRestylePass(documentLength: storage.length)
        isRestyling = false
        // A scroller that appears or hides during the restyle changes the width it used.
        scheduleResizeRestyleIfWidthChanged(for: textView)
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
        lastSyncedConfiguration = SyncedStyleConfiguration(viewModel: viewModel)
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

    private func styleResult(
        storage: NSTextStorage,
        parameters: MarkdownStyleParameters,
        selectedRange: NSRange,
        edit: MarkdownTextEdit?,
        incremental: Bool
    ) -> MarkdownStyleResult {
        if incremental, let previous = styleRecord {
            switch MarkdownLiveStyler.restyleIncrementally(
                storage, parameters: parameters, selectedRange: selectedRange, previous: previous, edit: edit
            ) {
            case .restyled(let result):
                lastFullRestyleReason = nil
                return result
            case .needsFullRestyle(let reason):
                lastFullRestyleReason = reason
            }
        } else {
            lastFullRestyleReason = incremental ? .noRecord : .notRequested
        }
        return MarkdownLiveStyler.styleDocument(storage, parameters: parameters, selectedRange: selectedRange)
    }

    /// Clears spell checker marks on code, math, and table text in the restyled ranges. Marks
    /// elsewhere were cleared when those lines were styled.
    private func clearSpellingMarks(
        textView: HybridMarkdownTextView,
        storage: NSTextStorage,
        decorations: [LineDecoration],
        restyledRanges: [NSRange]
    ) {
        guard let lm = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (storage.string as NSString).length)
        let enabled = viewModel.spellCheckEnabled
        defer { lastSpellCheckEnabled = enabled }
        guard enabled else {
            if lastSpellCheckEnabled != false {
                lm.removeTemporaryAttribute(.spellingState, forCharacterRange: fullRange)
            }
            return
        }
        let ranges = lastSpellCheckEnabled == true ? restyledRanges : [fullRange]
        let isFull = ranges == [fullRange]
        for dec in decorations where isFull || ranges.contains(where: { NSLocationInRange(dec.lineRange.location, $0) }) {
            lm.removeTemporaryAttribute(.spellingState, forCharacterRange: dec.lineRange)
        }
        for range in ranges {
            storage.enumerateAttribute(MarkdownLiveStyler.noSpellCheckAttributeKey, in: range, options: []) { val, range, _ in
                if val != nil {
                    lm.removeTemporaryAttribute(.spellingState, forCharacterRange: range)
                }
            }
        }
    }

    /// Rewraps edited paragraphs to the source line width once the selection is outside
    /// them. Runs after the current edit and selection change complete.
    func reflowEditedParagraphsOutsideSelection() {
        EditorPerfScope.bind(perf) {
            reflowEditedParagraphs()
        }
    }

    private func reflowEditedParagraphs() {
        guard let tv = textView, !reflowAnchors.isEmpty, !isApplyingReflow else { return }
        if LaTeXLiveStyler.isLaTeXOrBibTeXDocument(tv.string, fileURL: viewModel.currentFileURL) {
            reflowAnchors.removeAll()
            return
        }
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
                (current as NSString).substring(with: edit.range) != edit.replacement
            else { continue }
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
}
