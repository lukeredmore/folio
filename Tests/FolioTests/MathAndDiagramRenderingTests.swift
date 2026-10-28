import AppKit
import XCTest
@testable import Folio

final class MathAndDiagramRenderingTests: XCTestCase {

    func testLaTeXMathRendererLayoutAndDecorations() {
        let box = LaTeXMathRenderer.layoutWithFallbackEngine(#"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}"#, baseFontSize: 18, isDisplayStyle: true)
        assertMathMetrics(box, width: 90.5, ascent: 26.19, descent: 20.25, "Engine layout of Gauss's law")

        let sample = """
            First line here.
            Inline math $\\nabla \\cdot \\mathbf{E} = \\frac{\\rho}{\\varepsilon_0}$ here.

            $$
            \\mathcal{L}_{\\text{Folio}} = \\int_{-\\infty}^{\\infty} e^{-x^2} dx
            $$
            """
        let storage = NSTextStorage(string: sample)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0)
        )

        XCTAssertTrue(
            analysis.decorations.contains(where: {
                if case .inlineMathRendered(let latex, _, _, _) = $0.kind {
                    return latex.contains("nabla")
                }
                return false
            }), "Inactive line with $...$ should produce an inlineMathRendered decoration")

        XCTAssertTrue(
            analysis.decorations.contains(where: {
                if case .mathBlockRendered(let latex, _, _) = $0.kind {
                    return latex.contains("int")
                }
                return false
            }), "Inactive $$...$$ block should produce a mathBlockRendered decoration")
    }

    func testCoreEngineFFIIntegration() {
        let ffiBox = LaTeXMathRenderer.layoutLatex(#"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}"#, baseFontSize: 18, isDisplayStyle: true)
        XCTAssertTrue(ffiBox.usesNativeOpenTypeMath)
        assertMathMetrics(ffiBox, width: 95, ascent: 24, descent: 21, "SwiftMath layout of Gauss's law")

        let plain = LaTeXMathRenderer.plainTextSummary(of: #"\frac{\alpha}{\beta}"#)
        XCTAssertTrue(plain.contains("α"))
        XCTAssertTrue(plain.contains("β"))
    }

    @MainActor
    func testUnmatchedEmphasisDoesNotBacktrackOrHang() throws {
        // Regression test for catastrophic O(2^N) backtracking when a line contains an unmatched
        // opening `_` or `*` delimiter (such as `_subscriptions: Vec<Subscription>` inside inline code
        // in AGENTS.md) followed by 40+ characters without a matching closing delimiter.
        let pathologicalMarkdown = """
            # Agent Guidelines

            - When calling `cx.subscribe`, `cx.observe`, etc., never drop the returned `Subscription` without storing it (e.g., `cx.subscribe(...).detach()` is almost always a bug, unless `cx` is the `App` itself). Store subscriptions in a `_subscriptions: Vec<Subscription>` field on the struct so they are tied to the entity's lifetime.
            - Another line with unmatched *asterisk delimiter followed by a long sequence of words that has no closing asterisk anywhere on the line at all.
            - And an unmatched _underscore delimiter followed by a very long sequence of characters without any closing underscore anywhere on this line either!
            """

        let style: (String) -> Void = { markdown in
            _ = MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: markdown),
                theme: .daylight,
                typography: .default,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: NSRange(location: 0, length: 0),
                containerWidth: 720
            )
        }
        style(pathologicalMarkdown)

        // Backtracking grows exponentially with the length of the unmatched tail; linear code grows 4x.
        assertNearLinearScaling("unmatched emphasis tail", small: 40) { words in
            let tail = Array(repeating: "word", count: words).joined(separator: " ")
            let line = "- unmatched *asterisk \(tail) and _underscore \(tail) and `_subscriptions: Vec<Sub>` \(tail)"
            style(Array(repeating: line, count: 25).joined(separator: "\n"))
        }
    }

    @MainActor
    func testAdversarialMarkdownAndLatexNoExplosions() throws {
        // Comprehensive pentest suite for algorithmic complexity attacks (ReDoS, O(N^2) scanners,
        // stack-overflow recursion, and infinite loops on malformed delimiters).
        func adversarialMarkdown(_ n: Int) -> String {
            let adversarialLines: [String] = [
                // 1. Cubic O(N^3) hrRegex attack: alternating hyphens and spaces ending with non-hyphen
                String(repeating: "- ", count: n) + "a",
                String(repeating: "* ", count: n) + "a",
                String(repeating: "_ ", count: n) + "a",
                // 2. Quadratic O(N^2) headingRegex attack: trailing spaces + hashes + non-hash
                "# " + String(repeating: " ", count: n) + String(repeating: "#", count: n) + "a",
                // 3. Quadratic O(N^2) autolink email domain attack without closing '>'
                "<user@" + String(repeating: "a.", count: n),
                // 4. Repeated unmatched inline code backtick runs of different lengths
                String(repeating: "`a ", count: n),
                String(repeating: "``a ", count: n),
                String(repeating: "```a ", count: n),
                // 5. Repeated unmatched emphasis, strikethrough, and highlight openers
                String(repeating: "*a ", count: n),
                String(repeating: "_a ", count: n),
                String(repeating: "**a ", count: n),
                String(repeating: "__a ", count: n),
                String(repeating: "***a ", count: n),
                String(repeating: "~~a ", count: n),
                String(repeating: "==a ", count: n),
                // 6. Repeated unmatched brackets and unclosed link destinations
                String(repeating: "[a ", count: n),
                String(repeating: "[a](https://example.com/", count: n / 2),
                String(repeating: "[outer ", count: n) + "[inner](https://example.com)",
                // 7. Table candidate line with pipes and thousands of unmatched backticks and '$'
                "| " + String(repeating: "`a ", count: n) + " | " + String(repeating: "$a ", count: n) + " |"
            ]
            return adversarialLines.joined(separator: "\n\n")
        }
        let style: (String) -> MarkdownDocumentAnalysis = { markdown in
            MarkdownLiveStyler.applyStyles(
                to: NSTextStorage(string: markdown),
                theme: .daylight,
                typography: .default,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: NSRange(location: 0, length: 0),
                containerWidth: 720
            )
        }
        XCTAssertEqual(style(adversarialMarkdown(1500)).headings.count, 1)
        assertNearLinearScaling("adversarial markdown styling", small: 400) { n in
            _ = style(adversarialMarkdown(n))
        }

        // 8. LaTeX parser pentests: deeply nested braces, scripts, stray '}', and \left...\rightarrow...\right
        let deepBraces = String(repeating: "{", count: 500) + "x+1" + String(repeating: "}", count: 500)
        let deepSupers = String(repeating: "x^", count: 500) + "2"
        let strayClosingBraces = "}}}}}}x + y}}}}}}"
        let leftWithRightArrow = #"\left( a \rightarrow b } c \right)"#

        let box1 = LaTeXMathRenderer.layoutWithFallbackEngine(deepBraces, baseFontSize: 16, isDisplayStyle: true)
        let box2 = LaTeXMathRenderer.layoutWithFallbackEngine(deepSupers, baseFontSize: 16, isDisplayStyle: true)
        let box3 = LaTeXMathRenderer.layoutWithFallbackEngine(strayClosingBraces, baseFontSize: 16, isDisplayStyle: true)
        let box4 = LaTeXMathRenderer.layoutLatex(leftWithRightArrow, baseFontSize: 16, isDisplayStyle: true)
        let summary4 = LaTeXMathRenderer.plainTextSummary(of: leftWithRightArrow)
        assertNearLinearScaling("nested LaTeX layout", small: 125) { depth in
            // Repeat so each timing is several milliseconds and timer noise stays small.
            for _ in 0..<5 {
                let braces = String(repeating: "{", count: depth) + "x+1" + String(repeating: "}", count: depth)
                let supers = String(repeating: "x^", count: depth) + "2"
                _ = LaTeXMathRenderer.layoutWithFallbackEngine(braces, baseFontSize: 16, isDisplayStyle: true)
                _ = LaTeXMathRenderer.layoutWithFallbackEngine(supers, baseFontSize: 16, isDisplayStyle: true)
            }
        }
        // Input the parser rejects (nesting limit, double superscript, unbalanced braces) degrades to plain text.
        assertPlainTextFallback(box1, for: deepBraces, baseFontSize: 16)
        assertPlainTextFallback(box2, for: deepSupers, baseFontSize: 16)
        assertPlainTextFallback(box3, for: strayClosingBraces, baseFontSize: 16)
        assertPlainTextFallback(box4, for: leftWithRightArrow, baseFontSize: 16)
        XCTAssertEqual(LaTeXMathRenderer.plainTextSummary(of: deepBraces), "x+1")
        XCTAssertTrue(summary4.contains("→"))
    }
}
