import XCTest
@testable import Folio

/// Macros that lay out `\\`-separated alternatives in an `array`, such as clqr's `\xorGOO`.
final class LaTeXArrayAlternativesTests: XCTestCase {
    private let definitions = #"""
        \newcommand{\Kw}[1]{\textbf{#1}}
        \newcommand{\Stack}[2]{\text{\(\!%
            \left.%
            \begin{array}{l}%
              #1%
            \end{array}\!%
            \right#2%
            \)}}
        \newcommand{\Choice}[2]{\text{\(%
            \left\{\!%
            \begin{array}{l}%
              #1%
            \end{array}\!%
            \right#2%
            \)}}
        \newcommand{\Some}[2]{\text{\(\left\{\!\left|\begin{array}{l}#1\end{array}\!\right.\right#2\)}}
        """#

    private var macros: [String: LaTeXMacroDefinition] { LaTeXMacroExpander.extractDocumentMacros(from: definitions) }

    private func bold(_ text: String) -> LaTeXProseSegment {
        var style = LaTeXProseStyle()
        style.bold = true
        return .text(text, style)
    }

    private func plain(_ text: String) -> LaTeXProseSegment { .text(text, LaTeXProseStyle()) }

    func testBodiesWithArrayLayoutsParse() throws {
        let stack = try XCTUnwrap(LaTeXArrayAlternatives.parse(try XCTUnwrap(macros["\\Stack"]).replacement))
        XCTAssertEqual(stack, LaTeXArrayAlternatives(rowsArgument: 1, opening: [.text("")], closing: [.argument(2)]))
        let choice = try XCTUnwrap(LaTeXArrayAlternatives.parse(try XCTUnwrap(macros["\\Choice"]).replacement))
        XCTAssertEqual(choice.opening, [.text("{")])
        let some = try XCTUnwrap(LaTeXArrayAlternatives.parse(try XCTUnwrap(macros["\\Some"]).replacement))
        XCTAssertEqual(some.opening, [.text("{"), .text("|")])
        XCTAssertEqual(some.closing, [.text(""), .argument(2)])
    }

    func testOtherBodiesDoNotParse() {
        for body in [
            #"\textbf{#1}"#,
            #"\begin{array}{l}#1\end{array} and text"#,
            #"\(\leftarrow\begin{array}{l}#1\end{array}\)"#,
            #"\(\left.\begin{array}{l}x\end{array}\right.\)"#,
            #"\(\left\langle\begin{array}{l}#1\end{array}\right\rangle\) tail"#
        ] {
            XCTAssertNil(LaTeXArrayAlternatives.parse(body), body)
        }
    }

    func testRowsSplitOnlyAtTopLevelBreaks() {
        XCTAssertEqual(LaTeXArrayAlternatives.rows(of: #"a\\ {b\\c} \\[2mm] d\\"#), ["a", #"{b\\c}"#, "d"])
        XCTAssertEqual(LaTeXArrayAlternatives.rows(of: #" \\ "#), [])
    }

    func testRowsWithoutOpeningDelimiterStack() {
        let segments = LaTeXProseMacroExpander.expandCall(source: #"\Stack{(\Kw{open})\\ (\Kw{close})}{.}"#, macros: macros)?.segments
        XCTAssertEqual(segments, [plain("("), bold("open"), plain(")"), .lineBreak, plain("("), bold("close"), plain(")")])
    }

    func testRowsWithOpeningDelimiterJoinOnOneLine() {
        let segments = LaTeXProseMacroExpander.expandCall(source: #"\Choice{\Kw{read}\\\Kw{write}}{\}}"#, macros: macros)?.segments
        XCTAssertEqual(segments, [plain("{"), bold("read"), plain(" | "), bold("write"), plain("}")])
    }

    func testClosingDelimiterKeepsItsScript() {
        let segments = LaTeXProseMacroExpander.expandCall(source: #"\Some{a\\b}{\}^{\!*}}"#, macros: macros)?.segments
        XCTAssertEqual(segments, [plain("{|a | b}"), .math(#"{}^{\!*}"#, LaTeXProseStyle())])
    }

    func testUnknownDelimiterOrEmptyRowsFail() {
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Stack{a\\b}{\foo}"#, macros: macros))
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Stack{a\\b}{\}x}"#, macros: macros))
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Stack{ }{.}"#, macros: macros))
    }
}
