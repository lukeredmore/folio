import CoreFoundation
import Foundation

/// Measures how long the main run loop stays busy between waits. A busy period starts when the
/// loop enters or wakes and ends when it is about to wait or exits. The end observer runs last,
/// so the Core Animation commit and SwiftUI updates in the same pass are included.
@MainActor
final class MainThreadStallMonitor {
    private(set) var maxStall: TimeInterval = 0
    private(set) var totalBusy: TimeInterval = 0
    private(set) var busyPeriods = 0
    private var busySince: CFAbsoluteTime?
    private var observers: [CFRunLoopObserver] = []

    func start() {
        guard observers.isEmpty else { return }
        let begin = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let end = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        observers = [
            makeObserver(activities: begin, order: CFIndex.min) { $0.markBusy() },
            makeObserver(activities: end, order: CFIndex.max) { $0.markIdle() }
        ]
        for observer in observers {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    func stop() {
        for observer in observers {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
        busySince = nil
    }

    func reset() {
        maxStall = 0
        totalBusy = 0
        busyPeriods = 0
        busySince = nil
    }

    private func markBusy() {
        if busySince == nil {
            busySince = CFAbsoluteTimeGetCurrent()
        }
    }

    private func markIdle() {
        guard let since = busySince else { return }
        busySince = nil
        let duration = CFAbsoluteTimeGetCurrent() - since
        totalBusy += duration
        busyPeriods += 1
        maxStall = max(maxStall, duration)
    }

    private func makeObserver(
        activities: CFOptionFlags,
        order: CFIndex,
        _ action: @escaping @MainActor (MainThreadStallMonitor) -> Void
    ) -> CFRunLoopObserver {
        CFRunLoopObserverCreateWithHandler(nil, activities, true, order) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
    }
}
