import XCTest
@testable import Folio

/// Text-mode expansion of user macros with arguments, and its caps.
final class LaTeXProseMacroExpansionTests: XCTestCase {
    private func macros(_ source: String) -> [String: LaTeXMacroDefinition] {
        LaTeXMacroExpander.extractDocumentMacros(from: source)
    }

    private func style(_ change: (inout LaTeXProseStyle) -> Void) -> LaTeXProseStyle {
        var style = LaTeXProseStyle()
        change(&style)
        return style
    }

    func testArgumentsAreSubstitutedAndConsumed() throws {
        let defs = macros(#"\newcommand{\pair}[2]{#1 and #2}"#)
        let expansion = try XCTUnwrap(LaTeXProseMacroExpander.expandCall(source: #"\pair{salt}{pepper}s tail"#, macros: defs))
        XCTAssertEqual(expansion.consumedLength, (#"\pair{salt}{pepper}"# as NSString).length)
        XCTAssertEqual(expansion.segments, [.text("salt and pepper", LaTeXProseStyle())])
    }

    func testOptionalDefaultArgument() throws {
        let defs = macros(#"\newcommand{\opt}[2][none]{#2=#1}"#)
        XCTAssertEqual(LaTeXProseMacroExpander.expandCall(source: #"\opt{x}"#, macros: defs)?.segments, [.text("x=none", LaTeXProseStyle())])
        let given = try XCTUnwrap(LaTeXProseMacroExpander.expandCall(source: #"\opt[on]{x} y"#, macros: defs))
        XCTAssertEqual(given.segments, [.text("x=on", LaTeXProseStyle())])
        XCTAssertEqual(given.consumedLength, 11)
    }

    func testNestedMacrosInheritStyle() {
        let defs = macros(#"\newcommand{\Kw}[1]{\textbf{#1}}\newcommand{\Arg}[1]{\textit{#1}}\newcommand{\Pair}[2]{\Kw{#1 \Arg{#2}}}"#)
        let segments = LaTeXProseMacroExpander.expandCall(source: #"\Pair{open}{file}"#, macros: defs)?.segments
        XCTAssertEqual(
            segments,
            [
                .text("open ", style { $0.bold = true }),
                .text(
                    "file",
                    style {
                        $0.bold = true; $0.italic = true
                    })
            ]
        )
    }

    func testFontCommandsMapToStyles() {
        let cases: [(String, LaTeXProseStyle)] = [
            (#"\textbf{w}"#, style { $0.bold = true }),
            (#"{\bfseries w}"#, style { $0.bold = true }),
            (#"{\fontseries{b}\selectfont w}"#, style { $0.bold = true }),
            (#"\emph{w}"#, style { $0.italic = true }),
            (#"{\itshape w}"#, style { $0.italic = true }),
            (#"{\slshape w}"#, style { $0.italic = true }),
            (#"\texttt{w}"#, style { $0.monospace = true }),
            (#"{\ttfamily w}"#, style { $0.monospace = true }),
            (#"\text{{\fontfamily{cmtt}\selectfont w}}"#, style { $0.monospace = true }),
            (#"{\sffamily w}"#, style { $0.sans = true }),
            (#"\textsc{w}"#, style { $0.smallCaps = true }),
            (#"\uline{w}"#, style { $0.underline = true }),
            (#"\textsubscript{w}"#, style { $0.script = .lowered }),
            (#"\lowercase{W}"#, style { $0.letterCase = .lower })
        ]
        for (tex, expected) in cases {
            XCTAssertEqual(LaTeXProseMacroExpander.render(tex, macros: [:]), [.text("w", expected)], tex)
        }
    }

    func testFontNoiseIsDroppedAndGroupsScopeDeclarations() {
        let segments = LaTeXProseMacroExpander.render(#"\text{a{\bfseries b\/}c}\index{k}\hskip1em\setlength{\x}{2pt}"#, macros: [:])
        XCTAssertEqual(segments, [.text("a", LaTeXProseStyle()), .text("b", style { $0.bold = true }), .text("c", LaTeXProseStyle())])
    }

    func testMathAndLineBreaksBecomeSegments() {
        let segments = LaTeXProseMacroExpander.render(#"a$x^2$\\b"#, macros: [:])
        XCTAssertEqual(segments, [.text("a", LaTeXProseStyle()), .math("x^2", LaTeXProseStyle()), .lineBreak, .text("b", LaTeXProseStyle())])
    }

    func testStarredCallFallsBackToBaseMacroWithArguments() throws {
        let defs = macros(#"\newcommand{\FN}[1]{\textbf{#1}}\newcommand{\Z}{z}"#)
        let starred = try XCTUnwrap(LaTeXProseMacroExpander.expandCall(source: #"\FN*{f}"#, macros: defs))
        XCTAssertEqual(starred.consumedLength, 7)
        XCTAssertEqual(starred.segments, [.text("f", style { $0.bold = true })])
        let bare = try XCTUnwrap(LaTeXProseMacroExpander.expandCall(source: #"\Z*"#, macros: defs))
        XCTAssertEqual(bare.consumedLength, 2, "a macro without arguments leaves the star as text")
    }

    func testEmptyBracesAfterZeroArgumentCallAreConsumed() throws {
        let defs = macros(#"\newcommand{\P}{Widget}"#)
        XCTAssertEqual(try XCTUnwrap(LaTeXProseMacroExpander.expandCall(source: #"\P{} x"#, macros: defs)).consumedLength, 4)
    }

    func testUnknownCommandsAndMissingArgumentsFail() {
        let defs = macros(#"\newcommand{\L}[1]{\vspace{2pt}#1}\newcommand{\Two}[2]{#1#2}"#)
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\L{x}"#, macros: defs), "layout commands are not rendered")
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Two{x}"#, macros: defs), "the line must supply every argument")
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Unknown{x}"#, macros: defs))
        XCTAssertNil(LaTeXProseMacroExpander.render("a & b", macros: [:]), "alignment characters are not text")
    }

    func testRecursionStopsAtDepthCap() {
        let defs = macros(#"\newcommand{\Spin}{\Spin}\newcommand{\Deep}[1]{\textbf{#1}}"#)
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Spin"#, macros: defs))
        let nested = String(repeating: #"\Deep{"#, count: 5) + "x" + String(repeating: "}", count: 5)
        var limits = LaTeXProseMacroExpander.Limits()
        limits.maxDepth = 5
        XCTAssertNotNil(LaTeXProseMacroExpander.expandCall(source: nested, macros: defs, limits: limits))
        limits.maxDepth = 4
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: nested, macros: defs, limits: limits))
    }

    func testExponentialExpansionStopsAtSizeCap() {
        var source = #"\newcommand{\A0}{xxxxxxxx}"#.replacingOccurrences(of: "A0", with: "Aa")
        let names = ["Aa", "Ab", "Ac", "Ad", "Ae", "Af", "Ag", "Ah", "Ai", "Aj", "Ak", "Al"]
        for (previous, name) in zip(names, names.dropFirst()) {
            source += "\\newcommand{\\\(name)}{\\\(previous)\\\(previous)}"
        }
        let defs = macros(source)
        XCTAssertNotNil(LaTeXProseMacroExpander.expandCall(source: #"\Ad"#, macros: defs), "small expansions render")
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: #"\Al"#, macros: defs), "2^11 copies exceed the size cap")
    }

    func testSegmentCap() {
        let defs = macros(#"\newcommand{\M}[1]{#1}"#)
        let call = #"\M{"# + String(repeating: #"\textbf{a}b"#, count: 200) + "}"
        XCTAssertNil(LaTeXProseMacroExpander.expandCall(source: call, macros: defs))
        var limits = LaTeXProseMacroExpander.Limits()
        limits.maxSegments = 1_000
        XCTAssertNotNil(LaTeXProseMacroExpander.expandCall(source: call, macros: defs, limits: limits))
    }
}
