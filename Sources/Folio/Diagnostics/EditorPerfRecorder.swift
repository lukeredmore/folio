import Foundation
import os

/// Owner of one editor's `EditorPerfCounters`. Each editor coordinator has its own recorder.
/// Static styler and parser code records into the recorder bound by `EditorPerfScope`, so the
/// counts stay per editor without global state. Thread-safe, because diagram and media work can
/// run off the main thread.
final class EditorPerfRecorder: Sendable {
    enum Count: Sendable {
        case parse
        case draw
    }

    private struct State: Sendable {
        var counters = EditorPerfCounters()
        var restylePassCharacters: Int?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var counters: EditorPerfCounters {
        state.withLock { $0.counters }
    }

    func increment(_ count: Count) {
        state.withLock { state in
            switch count {
            case .parse: state.counters.parseCount += 1
            case .draw: state.counters.drawCount += 1
            }
        }
    }

    func addDuration(_ phase: EditorPerfPhase, nanoseconds: UInt64) {
        state.withLock { state in
            state.counters.phaseNanoseconds[phase, default: 0] &+= nanoseconds
        }
    }

    func beginRestylePass() {
        state.withLock { $0.restylePassCharacters = 0 }
    }

    /// Adds an attribute edit to the open restyle pass. Edits outside a pass are ignored.
    func recordAttributeEdit(length: Int) {
        state.withLock { state in
            guard let characters = state.restylePassCharacters else { return }
            state.restylePassCharacters = characters + length
        }
    }

    func endRestylePass(documentLength: Int) {
        state.withLock { state in
            let characters = state.restylePassCharacters ?? 0
            state.restylePassCharacters = nil
            state.counters.restyleCount += 1
            state.counters.charactersRestyled += characters
            if documentLength > 0 && characters >= documentLength {
                state.counters.fullRangeRestyleCount += 1
            }
        }
    }
}

/// Binds the editor recorder that static code records into for the duration of a call.
enum EditorPerfScope {
    @TaskLocal static var recorder: EditorPerfRecorder?

    static func bind<T>(_ recorder: EditorPerfRecorder?, _ body: () throws -> T) rethrows -> T {
        try $recorder.withValue(recorder, operation: body)
    }
}
