import Foundation
import os

/// Editor work that is timed with an `OSSignposter` interval.
/// Intervals appear in Instruments under subsystem `app.folio.macos`, category `editor`.
enum EditorPerfPhase: String, CaseIterable, Sendable {
    case restyle
    case applyStyles
    case latexStyles
    case parse
    case draw
    case autosaveWrite
    case undoPersist
    case diagramRender
    case mediaDecode

    static let signposter = OSSignposter(subsystem: "app.folio.macos", category: "editor")

    var signpostName: StaticString {
        switch self {
        case .restyle: return "Coordinator.restyle"
        case .applyStyles: return "MarkdownLiveStyler.applyStyles"
        case .latexStyles: return "LaTeXLiveStyler.applyStyles"
        case .parse: return "parseSpecAST"
        case .draw: return "HybridMarkdownTextView.draw"
        case .autosaveWrite: return "autosaveWrite"
        case .undoPersist: return "persistUndoTimelines"
        case .diagramRender: return "DiagramImageRenderer.render"
        case .mediaDecode: return "mediaImageDecode"
        }
    }

    /// Starts an interval. Call `end()` on the result, usually from a `defer`.
    func begin() -> EditorPerfSpan {
        EditorPerfSpan(phase: self)
    }

    /// Runs `body` inside an interval for this phase.
    func measure<T>(_ body: () throws -> T) rethrows -> T {
        let span = begin()
        defer { span.end() }
        return try body()
    }
}

/// One open signpost interval. It also adds its duration to the editor recorder that was in
/// scope when it began, if any.
struct EditorPerfSpan {
    private let phase: EditorPerfPhase
    private let name: StaticString
    private let state: OSSignpostIntervalState
    private let recorder: EditorPerfRecorder?
    private let startNanoseconds: UInt64

    init(phase: EditorPerfPhase) {
        let signposter = EditorPerfPhase.signposter
        self.phase = phase
        name = phase.signpostName
        state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        recorder = EditorPerfScope.recorder
        startNanoseconds = recorder == nil ? 0 : clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    func end() {
        EditorPerfPhase.signposter.endInterval(name, state)
        guard let recorder else { return }
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- startNanoseconds
        recorder.addDuration(phase, nanoseconds: elapsed)
    }
}
