import Foundation
@testable import Folio

/// Writes perf measurements to `$TEST_UNDECLARED_OUTPUTS_DIR/perf.json`, which Bazel keeps in
/// `bazel-testlogs/FolioTests/test.outputs/`. Values are for reading and comparing; no test
/// asserts on the milliseconds written here.
@MainActor
enum PerfReport {
    private static var scenarios: [String: [String: Any]] = [:]

    static var outputURL: URL? {
        guard let dir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"],
              !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("perf.json")
    }

    static func record(_ scenario: String, _ values: [String: Any]) {
        scenarios[scenario] = values
        guard let url = outputURL else { return }
        let payload: [String: Any] = ["schema": 1, "scenarios": scenarios]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Counter deltas and per-phase milliseconds in a JSON-friendly form.
    static func values(_ delta: EditorPerfCounters, keys: Int = 1) -> [String: Any] {
        let perKey = Double(max(keys, 1))
        var phases: [String: Double] = [:]
        for (phase, nanos) in delta.phaseNanoseconds {
            phases[phase.rawValue] = Double(nanos) / 1_000_000 / perKey
        }
        return [
            "restyleCount": delta.restyleCount,
            "fullRangeRestyleCount": delta.fullRangeRestyleCount,
            "charactersRestyled": delta.charactersRestyled,
            "parseCount": delta.parseCount,
            "drawCount": delta.drawCount,
            "phaseMillisecondsPerKey": phases
        ]
    }
}

extension EditorPerfCounters {
    /// Work done between `earlier` and `self`.
    func delta(since earlier: EditorPerfCounters) -> EditorPerfCounters {
        var result = EditorPerfCounters()
        result.restyleCount = restyleCount - earlier.restyleCount
        result.fullRangeRestyleCount = fullRangeRestyleCount - earlier.fullRangeRestyleCount
        result.charactersRestyled = charactersRestyled - earlier.charactersRestyled
        result.parseCount = parseCount - earlier.parseCount
        result.drawCount = drawCount - earlier.drawCount
        for (phase, nanos) in phaseNanoseconds {
            result.phaseNanoseconds[phase] = nanos &- (earlier.phaseNanoseconds[phase] ?? 0)
        }
        return result
    }
}

extension WorkspacePerfCounters {
    func delta(since earlier: WorkspacePerfCounters) -> WorkspacePerfCounters {
        WorkspacePerfCounters(
            undoPersistCount: undoPersistCount - earlier.undoPersistCount,
            autosaveWriteCount: autosaveWriteCount - earlier.autosaveWriteCount
        )
    }
}
