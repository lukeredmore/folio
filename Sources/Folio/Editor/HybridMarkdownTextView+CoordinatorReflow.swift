import AppKit

extension HybridMarkdownEditorRepresentable.Coordinator {

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
}
