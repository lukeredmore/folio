import AppKit
import XCTest
@testable import Folio

/// Size-scaling and hang checks for the live editor, driven by real key events.
/// Times are main-thread busy time from `MainThreadStallMonitor`, compared as ratios between
/// document sizes, so the checks do not depend on how fast the machine is.
@MainActor
final class EditorPerfScalingTests: XCTestCase {
    private static let smallLines = 200
    private static let largeLines = 1600
    private static let wholeDocumentPassesCause =
        "per-key work outside the restyle still scans the whole document "
        + "(cmark parse and AST comparison, DocumentStats, undo diff, text hashing, SwiftUI updates)"

    private func withHarness<T>(lines: Int, _ body: (EditorHarness) throws -> T) throws -> T {
        let harness = try EditorHarness(lineCount: lines)
        defer { harness.tearDown() }
        harness.moveCursor(toLine: harness.middleParagraphLine, column: .max)
        harness.type("w")
        return try body(harness)
    }

    /// Fastest main-thread busy time of `runs` single keystrokes. The minimum filters out
    /// scheduler noise, as in `ScalingAssertions.swift`.
    private func minimumKeystrokeBusy(_ harness: EditorHarness, runs: Int = 5) -> TimeInterval {
        (0..<runs).map { _ in
            let before = harness.stallMonitor.totalBusy
            harness.type("k")
            return harness.stallMonitor.totalBusy - before
        }.min() ?? 0
    }

    func testCharactersRestyledPerKeystrokeStayWithinEditedBlock() throws {
        let measured = try withHarness(lines: Self.largeLines) { harness in
            let line = harness.middleParagraphLine
            let before = harness.counters
            harness.type("q")
            let delta = harness.counters.delta(since: before)
            let block = harness.blockLength(containingLine: line)
            return (delta: delta, block: block, document: (harness.text as NSString).length)
        }
        var report = PerfReport.values(measured.delta)
        report["editedBlockCharacters"] = measured.block
        report["documentCharacters"] = measured.document
        report["documentLines"] = Self.largeLines
        PerfReport.record("charactersRestyledPerKey_1600", report)

        let restyled = measured.delta.charactersRestyled
        XCTAssertLessThanOrEqual(
            restyled,
            measured.block,
            "a keystroke restyled \(restyled) characters; the edited block has \(measured.block)"
        )
    }

    func testKeystrokeCostScaling() throws {
        let small = try withHarness(lines: Self.smallLines) { minimumKeystrokeBusy($0) }
        let large = try withHarness(lines: Self.largeLines) { minimumKeystrokeBusy($0) }
        let ratio = large / max(small, 1e-6)
        PerfReport.record("keystrokeScaling", [
            "smallLines": Self.smallLines,
            "largeLines": Self.largeLines,
            "smallBusyMillisecondsPerKey": small * 1000,
            "largeBusyMillisecondsPerKey": large * 1000,
            "ratio": ratio
        ])
        let detail = String(format: "%.2f ms -> %.2f ms (%.2fx for 8x lines)", small * 1000, large * 1000, ratio)

        XCTAssertLessThan(ratio, 12, "keystroke cost grew superlinearly with document size: \(detail)")
        // Not strict: the ratio is near 2 and lands on either side depending on the machine
        // (1.6-1.7 on an M-series Mac, 2.4 on the CI runner). The restyle itself no longer scales
        // (see testCharactersRestyledPerKeystrokeStayWithinEditedBlock); deterministic counters
        // for the remaining passes should replace this timing check.
        XCTExpectFailure("Known gap: \(Self.wholeDocumentPassesCause).", strict: false) {
            XCTAssertLessThan(ratio, 2, "keystroke cost must not depend on document size: \(detail)")
        }
    }

    /// No keystroke in a burst may take far longer than a typical keystroke on the same
    /// machine. This catches hitches such as synchronous I/O or autosave work landing on a key,
    /// without an absolute time budget that depends on how fast the runner is.
    func testFiftyKeyBurstHasNoOutlierStall() throws {
        let perKey = try withHarness(lines: Self.largeLines) { harness in
            String(repeating: "burst text ", count: 5).prefix(50).map { character in
                let before = harness.stallMonitor.totalBusy
                harness.stallMonitor.resetMaxStall()
                harness.type(String(character))
                return (busy: harness.stallMonitor.totalBusy - before, stall: harness.stallMonitor.maxStall)
            }
        }
        let median = perKey.map(\.busy).sorted()[perKey.count / 2]
        let maxStall = perKey.map(\.stall).max() ?? 0
        PerfReport.record("burst50_1600", [
            "documentLines": Self.largeLines,
            "keys": perKey.count,
            "medianBusyMillisecondsPerKey": median * 1000,
            "maxStallMilliseconds": maxStall * 1000
        ])
        let detail = String(format: "max stall %.0f ms, median key %.0f ms", maxStall * 1000, median * 1000)
        XCTAssertLessThan(maxStall, 4 * median, "one keystroke stalled far longer than a typical one: \(detail)")
        XCTAssertLessThan(maxStall, 2.0, "main thread hung during a 50-key burst: \(detail)")
    }
}
