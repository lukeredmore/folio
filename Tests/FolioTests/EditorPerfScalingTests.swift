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
    private static let fullRestyleCause = "full-document restyle per keystroke"

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
            let block = editedBlockLength(in: harness.text, line: line)
            return (delta: delta, block: block, document: (harness.text as NSString).length)
        }
        var report = PerfReport.values(measured.delta)
        report["editedBlockCharacters"] = measured.block
        report["documentCharacters"] = measured.document
        report["documentLines"] = Self.largeLines
        PerfReport.record("charactersRestyledPerKey_1600", report)

        let restyled = measured.delta.charactersRestyled
        XCTExpectFailure("Known gap: \(Self.fullRestyleCause). Remove this wrapper when fixed.", strict: true) {
            XCTAssertLessThanOrEqual(
                restyled,
                measured.block,
                "a keystroke restyled \(restyled) characters; the edited block has \(measured.block)"
            )
        }
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
        XCTExpectFailure("Known gap: \(Self.fullRestyleCause). Remove this wrapper when fixed.", strict: true) {
            XCTAssertLessThan(ratio, 2, "keystroke cost must not depend on document size: \(detail)")
        }
    }

    func testFiftyKeyBurstDoesNotStallMainThread() throws {
        let measured = try withHarness(lines: Self.largeLines) { harness in
            harness.stallMonitor.reset()
            let before = harness.counters
            harness.type(String(repeating: "burst text ", count: 5).prefix(50).description)
            return (maxStall: harness.stallMonitor.maxStall, delta: harness.counters.delta(since: before))
        }
        let stallMilliseconds = Int(measured.maxStall * 1000)
        var report = PerfReport.values(measured.delta, keys: 50)
        report["maxStallMilliseconds"] = measured.maxStall * 1000
        report["documentLines"] = Self.largeLines
        PerfReport.record("burst50_1600", report)
        XCTAssertLessThan(measured.maxStall, 0.25, "main thread stalled \(stallMilliseconds) ms during a 50-key burst")
    }

    /// Length of the run of non-blank lines that contains `line`.
    private func editedBlockLength(in text: String, line: Int) -> Int {
        let lines = text.components(separatedBy: "\n")
        var first = line
        let isBlank = { (index: Int) in lines[index].trimmingCharacters(in: .whitespaces).isEmpty }
        while first > 0 && !isBlank(first - 1) { first -= 1 }
        var last = line
        while last + 1 < lines.count && !isBlank(last + 1) { last += 1 }
        return lines[first...last].reduce(0) { $0 + ($1 as NSString).length + 1 }
    }
}
