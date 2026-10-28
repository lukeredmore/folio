import AppKit
import XCTest
@testable import Folio

extension XCTestCase {
    /// Asserts box metrics to within `accuracy` points, which absorbs SwiftMath's rounding up.
    func assertMathMetrics(
        _ box: MathLayoutBox,
        width: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        accuracy: CGFloat = 1.0,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(box.width, width, accuracy: accuracy, "\(label): width", file: file, line: line)
        XCTAssertEqual(box.ascent, ascent, accuracy: accuracy, "\(label): ascent", file: file, line: line)
        XCTAssertEqual(box.descent, descent, accuracy: accuracy, "\(label): descent", file: file, line: line)
    }

    /// Asserts the plain-text fallback metrics of `folio_engine::math::layout_latex`.
    func assertPlainTextFallback(
        _ box: MathLayoutBox,
        for latex: String,
        baseFontSize: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let em = baseFontSize * 1.18
        let characters = CGFloat(LaTeXMathRenderer.plainTextSummary(of: latex).unicodeScalars.count)
        XCTAssertFalse(box.usesNativeOpenTypeMath, "Plain-text fallback is not SwiftMath", file: file, line: line)
        assertMathMetrics(
            box,
            width: max(characters * em * 0.55, em * 0.5),
            ascent: em * 0.82,
            descent: em * 0.24,
            accuracy: 0.01,
            "plain-text fallback",
            file: file,
            line: line
        )
    }
}
