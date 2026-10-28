import AppKit

extension HybridMarkdownEditorRepresentable.Coordinator {

    func observeTextEdits(of storage: NSTextStorage) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordTextEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage
        )
    }

    /// Adds a character edit's `editedRange` to the edits since the last restyle.
    @objc func recordTextEdit(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters),
              storage.editedRange.location != NSNotFound else { return }
        let range = storage.editedRange
        let delta = storage.changeInLength
        if var edit = pendingTextEdit {
            edit.merge(editedRange: range, changeInLength: delta)
            pendingTextEdit = edit
        } else {
            pendingTextEdit = MarkdownTextEdit(range: range, changeInLength: delta)
        }
    }

    /// Restyles after input-method composition ends, if a text change was deferred during it.
    func restyleAfterMarkedText(textView: HybridMarkdownTextView) {
        guard isRestyleDeferredForMarkedText, !textView.hasMarkedText() else { return }
        isRestyleDeferredForMarkedText = false
        restyle(textView: textView, incremental: true)
    }

    func styleResult(
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
    func clearSpellingMarks(
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
}
