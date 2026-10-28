import Foundation

/// Runs debounced editor work on the main queue. Tests replace `.live` with a manual
/// scheduler so debounce behavior does not depend on wall-clock time.
struct EditorScheduler {
    var schedule: @MainActor (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void

    static let live = EditorScheduler { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
