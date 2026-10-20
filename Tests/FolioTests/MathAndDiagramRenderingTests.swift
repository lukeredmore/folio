import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class MathAndDiagramRenderingTests: XCTestCase {

    func testLaTeXMathRendererLayoutAndDecorations() {
        let node = LaTeXMathRenderer.parse(#"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}"#)
        let box = LaTeXMathRenderer.layout(node: node, baseFontSize: 18, isDisplayStyle: true)
        XCTAssertGreaterThan(box.width, 60)
        XCTAssertGreaterThan(box.ascent, 12)
        XCTAssertGreaterThan(box.descent, 6)

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

        XCTAssertTrue(analysis.decorations.contains(where: {
            if case .inlineMathRendered(let latex, _, _, _) = $0.kind {
                return latex.contains("nabla")
            }
            return false
        }), "Inactive line with $...$ should produce an inlineMathRendered decoration")

        XCTAssertTrue(analysis.decorations.contains(where: {
            if case .mathBlockRendered(let latex, _, _) = $0.kind {
                return latex.contains("int")
            }
            return false
        }), "Inactive $$...$$ block should produce a mathBlockRendered decoration")
    }

    func testCoreEngineFFIIntegration() {
        let ffiBox = LaTeXMathRenderer.layoutLatex(#"\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}"#, baseFontSize: 18, isDisplayStyle: true)
        XCTAssertGreaterThan(ffiBox.width, 60)
        XCTAssertGreaterThan(ffiBox.ascent, 12)
        XCTAssertGreaterThan(ffiBox.descent, 6)

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

        // Also verify full MainWindowView + HybridMarkdownTextView layout with AGENTS.md files if present on disk
        let candidatePaths = [
            "/Users/lukeredmore/Developer/Folio/third_party/zed/upstream/AGENTS.md",
            "/Users/lukeredmore/Developer/PDLaunch/AGENTS.md"
        ]
        let defaultsSuiteName = "com.folio.tests.perf.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { testDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        let vm = EditorWorkspaceViewModel(userDefaults: testDefaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 901, height: 1036),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        window.displayIfNeeded()

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            let t0 = CFAbsoluteTimeGetCurrent()
            vm.openFile(at: URL(fileURLWithPath: path))
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            window.displayIfNeeded()
            let dt = CFAbsoluteTimeGetCurrent() - t0
            XCTAssertLessThan(dt, 0.5, "Opening and rendering \(path) should complete in <0.5s, took \(dt)s")
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
                "| " + String(repeating: "`a ", count: n) + " | " + String(repeating: "$a ", count: n) + " |",
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

        let node1 = LaTeXMathRenderer.parse(deepBraces)
        let node2 = LaTeXMathRenderer.parse(deepSupers)
        let node3 = LaTeXMathRenderer.parse(strayClosingBraces)
        let node4 = LaTeXMathRenderer.parse(leftWithRightArrow)
        let box1 = LaTeXMathRenderer.layout(node: node1, baseFontSize: 16, isDisplayStyle: true)
        let box4 = LaTeXMathRenderer.layoutLatex(leftWithRightArrow, baseFontSize: 16, isDisplayStyle: true)
        let summary4 = LaTeXMathRenderer.plainTextSummary(of: leftWithRightArrow)
        assertNearLinearScaling("nested LaTeX layout", small: 125) { depth in
            // Repeat so each timing is several milliseconds and timer noise stays small.
            for _ in 0..<5 {
                let braces = String(repeating: "{", count: depth) + "x+1" + String(repeating: "}", count: depth)
                let supers = String(repeating: "x^", count: depth) + "2"
                _ = LaTeXMathRenderer.layout(node: LaTeXMathRenderer.parse(braces), baseFontSize: 16, isDisplayStyle: true)
                _ = LaTeXMathRenderer.layout(node: LaTeXMathRenderer.parse(supers), baseFontSize: 16, isDisplayStyle: true)
            }
        }
        XCTAssertGreaterThan(box1.width, 0)
        XCTAssertGreaterThan(box4.width, 0)
        XCTAssertTrue(summary4.contains("→"))
        _ = (node2, node3, node4)
    }
}
