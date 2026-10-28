import Foundation
@testable import Folio

/// Holds scheduled editor work until the test calls `flush()`.
@MainActor
final class ManualEditorScheduler {
    private var pending: [DispatchWorkItem] = []

    var scheduler: EditorScheduler {
        EditorScheduler { [weak self] _, work in self?.pending.append(work) }
    }

    /// Number of scheduled items that have not been cancelled.
    var liveCount: Int { pending.filter { !$0.isCancelled }.count }

    /// Runs every scheduled item that has not been cancelled, in order.
    func flush() {
        let items = pending
        pending.removeAll()
        for item in items where !item.isCancelled {
            item.perform()
        }
    }
}
