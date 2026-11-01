import Foundation
import XCTest

extension XCTestCase {
    /// Fastest of `runs` timings of `work`. The minimum filters out scheduler noise.
    func minimumDuration(runs: Int = 3, _ work: () -> Void) -> TimeInterval {
        (0..<runs).map { _ in
            let start = CFAbsoluteTimeGetCurrent()
            work()
            return CFAbsoluteTimeGetCurrent() - start
        }.min() ?? 0
    }

    /// Asserts that `work` scales near-linearly with input size. Compares run time at `small`
    /// and at 4x `small`, so the check does not depend on how fast the machine is: linear code
    /// grows about 4x, quadratic code about 16x. A warm-up run keeps one-time setup (font and
    /// regex loading) out of the timings, and a 10 s cap still catches hangs.
    func assertNearLinearScaling(
        _ label: String,
        small: Int,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ work: (Int) -> Void
    ) {
        let factor = 4
        let maxRatio = 10.0
        work(small)
        let tSmall = minimumDuration { work(small) }
        let tLarge = minimumDuration { work(small * factor) }
        let ratio = tLarge / max(tSmall, 1e-6)
        print(String(format: "%@: %.2f ms -> %.2f ms (%.2fx for %dx input)", label, tSmall * 1000, tLarge * 1000, ratio, factor))
        XCTAssertLessThan(
            ratio,
            maxRatio,
            String(
                format: "%@: %dx input took %.1fx longer (%.2f ms -> %.2f ms); linear is ~%dx, quadratic ~%dx",
                label, factor, ratio, tSmall * 1000, tLarge * 1000, factor, factor * factor),
            file: file,
            line: line
        )
        XCTAssertLessThan(tLarge, 10, "\(label): \(tLarge) s for the large input exceeds the 10 s hang cap", file: file, line: line)
    }
}
