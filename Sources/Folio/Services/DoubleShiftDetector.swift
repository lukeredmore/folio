import AppKit
import SwiftUI

/// State machine that detects an IntelliJ-style double-Shift tap (`Shift-Shift`)
/// without false-triggering when Shift is held with other keys or modifiers.
public struct DoubleShiftDetector: Sendable {
    public var maxHoldDuration: TimeInterval
    public var maxDoubleTapInterval: TimeInterval

    private var shiftDownTimestamp: TimeInterval?
    private var lastCleanTapReleaseTimestamp: TimeInterval?
    private var interruptedByOtherEvent: Bool = false

    public init(
        maxHoldDuration: TimeInterval = 0.35,
        maxDoubleTapInterval: TimeInterval = 0.40
    ) {
        self.maxHoldDuration = maxHoldDuration
        self.maxDoubleTapInterval = maxDoubleTapInterval
    }

    /// Processes a `.flagsChanged` event's modifier flags and timestamp.
    /// Returns `true` when two clean, bare `Shift` taps complete within `maxDoubleTapInterval`.
    public mutating func handleFlagsChanged(
        modifierFlags: NSEvent.ModifierFlags,
        timestamp: TimeInterval
    ) -> Bool {
        let relevantFlags = modifierFlags.intersection([.shift, .command, .option, .control])

        if relevantFlags == [.shift] {
            shiftDownTimestamp = timestamp
            interruptedByOtherEvent = false
            return false
        }

        if relevantFlags.isEmpty {
            guard let downTime = shiftDownTimestamp, !interruptedByOtherEvent else {
                shiftDownTimestamp = nil
                lastCleanTapReleaseTimestamp = nil
                interruptedByOtherEvent = false
                return false
            }
            shiftDownTimestamp = nil
            let holdDuration = timestamp - downTime
            guard holdDuration >= 0, holdDuration <= maxHoldDuration else {
                lastCleanTapReleaseTimestamp = nil
                return false
            }

            if let previousRelease = lastCleanTapReleaseTimestamp,
                (timestamp - previousRelease) >= 0,
                (timestamp - previousRelease) <= maxDoubleTapInterval
            {
                lastCleanTapReleaseTimestamp = nil
                return true
            } else {
                lastCleanTapReleaseTimestamp = timestamp
                return false
            }
        }

        shiftDownTimestamp = nil
        lastCleanTapReleaseTimestamp = nil
        interruptedByOtherEvent = true
        return false
    }

    /// Cancels any in-progress Shift tap sequence when another key or mouse button is pressed.
    public mutating func cancelSequence() {
        interruptedByOtherEvent = true
        shiftDownTimestamp = nil
        lastCleanTapReleaseTimestamp = nil
    }
}

struct DoubleShiftEventMonitorAccessor: NSViewRepresentable {
    let viewModel: EditorWorkspaceViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> PassThroughAccessorNSView {
        let view = PassThroughAccessorNSView(frame: .zero)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: PassThroughAccessorNSView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    static func dismantleNSView(_ nsView: PassThroughAccessorNSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var viewModel: EditorWorkspaceViewModel?
        var detector = DoubleShiftDetector()
        nonisolated(unsafe) var localMonitor: Any?

        init(viewModel: EditorWorkspaceViewModel) {
            self.viewModel = viewModel
        }

        deinit {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func startMonitoring() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                let (eventType, modifierFlags, timestamp, keyCode) = Self.extractEventFields(from: event)
                let shouldConsume = MainActor.assumeIsolated {
                    guard let self = self else { return false }
                    return self.handleEvent(
                        type: eventType,
                        modifierFlags: modifierFlags,
                        timestamp: timestamp,
                        keyCode: keyCode
                    )
                }
                return shouldConsume ? nil : event
            }
        }

        nonisolated static func extractEventFields(
            from event: NSEvent
        ) -> (NSEvent.EventType, NSEvent.ModifierFlags, TimeInterval, UInt16) {
            let eventType = event.type
            let modifierFlags = event.modifierFlags
            let timestamp = event.timestamp
            let keyCode: UInt16 =
                (eventType == .keyDown || eventType == .keyUp || eventType == .flagsChanged)
                ? event.keyCode
                : 0
            return (eventType, modifierFlags, timestamp, keyCode)
        }

        func processMonitoredEvent(_ event: NSEvent) -> NSEvent? {
            let (eventType, modifierFlags, timestamp, keyCode) = Self.extractEventFields(from: event)
            let shouldConsume = handleEvent(
                type: eventType,
                modifierFlags: modifierFlags,
                timestamp: timestamp,
                keyCode: keyCode
            )
            return shouldConsume ? nil : event
        }

        func stopMonitoring() {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }

        private func handleEvent(
            type: NSEvent.EventType,
            modifierFlags: NSEvent.ModifierFlags,
            timestamp: TimeInterval,
            keyCode: UInt16
        ) -> Bool {
            switch type {
            case .flagsChanged:
                if detector.handleFlagsChanged(
                    modifierFlags: modifierFlags,
                    timestamp: timestamp
                ) {
                    viewModel?.toggleQuickOpen()
                }
                return false

            case .keyDown:
                detector.cancelSequence()
                guard let vm = viewModel else { return false }
                if vm.showQuickOpen {
                    switch keyCode {
                    case 53: // Escape
                        vm.closeQuickOpen()
                        return true
                    case 125: // Down Arrow
                        vm.moveQuickOpenSelection(by: 1)
                        return true
                    case 126: // Up Arrow
                        vm.moveQuickOpenSelection(by: -1)
                        return true
                    default:
                        return false
                    }
                }
                if keyCode == 53, vm.showFindReplaceBar {
                    vm.closeDocumentFindBar()
                    return true
                }
                return false

            case .leftMouseDown, .rightMouseDown:
                detector.cancelSequence()
                return false

            default:
                return false
            }
        }
    }
}
