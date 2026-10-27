import AppKit

extension HybridMarkdownEditorRepresentable.Coordinator {

    /// Snapshot of the work this editor has done since it was created.
    var perfCounters: EditorPerfCounters {
        perf.counters
    }

    /// Adds the attribute range that a restyle pass edited to the pass's character count.
    @objc func recordRestyleAttributeEdit(_ notification: Notification) {
        guard isRestyling,
              let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedAttributes),
              storage.editedRange.location != NSNotFound else { return }
        perf.recordAttributeEdit(length: storage.editedRange.length)
    }

    func observePerfEdits(of storage: NSTextStorage) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordRestyleAttributeEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage
        )
    }
}
