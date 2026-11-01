import Foundation

/// Runs debounced editor work on the main queue. Tests replace `.live` with a manual
/// scheduler so debounce behavior does not depend on wall-clock time.
package struct EditorScheduler {
    package var schedule: @MainActor (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void

    package init(schedule: @escaping @MainActor (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void) {
        self.schedule = schedule
    }

    package static let live = EditorScheduler { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
