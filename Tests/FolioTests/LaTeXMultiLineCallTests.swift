import AppKit
import XCTest
@testable import Folio

/// User macro calls whose arguments continue on later lines, and calls whose layout-only body
/// is drawn transparently.
@MainActor
final class LaTeXMultiLineCallTests: XCTestCase {
    private let preamble = #"""
        \def\note{$\triangleright$\hskip1ex}
        \newlength{\W}
        \def\ENTRY#1 #2 {\settowidth{\W}{#1}\item{}#1\hfill\note#2}
        \def\Two#1 #2 {\item{}#1\hfill#2}
        \newcommand{\Kw}[1]{\textbf{#1}}
        \newcommand{\Arg}[1]{\textit{#1}}
        """#

    private var macros: [String: LaTeXMacroDefinition] { LaTeXMacroExpander.extractDocumentMacros(from: preamble) }

    private func lines(_ body: String, cursorOnBodyLine: Int? = nil) -> [String] {
        let start = LaTeXStyledDocument.bodyStartLine(preamble: preamble)
        let all = LaTeXStyledDocument.renderedLines(
            LaTeXStyledDocument.document(preamble: preamble, body: body),
            cursorLine: cursorOnBodyLine.map { start + $0 } ?? 0
        )
        return Array(all[start..<(start + body.components(separatedBy: "\n").count)])
    }

    private let entry = #"""
        \ENTRY{(\Kw{open} \Arg{
            file})}
        {
          Opens \Arg{file}. % says what it does
        }
        """#

    func testLayoutOnlyMacroIsTransparent() throws {
        let def = try XCTUnwrap(macros["\\ENTRY"])
        let layout = try XCTUnwrap(LaTeXTransparentMacro.analyze(def, macros: macros))
        XCTAssertEqual(layout.separators[1], [.math(#"\triangleright"#, LaTeXProseStyle()), .text(" ", LaTeXProseStyle())])
        XCTAssertNotNil(LaTeXTransparentMacro.analyze(try XCTUnwrap(macros["\\Two"]), macros: macros))
        XCTAssertNil(LaTeXTransparentMacro.analyze(try XCTUnwrap(macros["\\Kw"]), macros: macros), "a body that renders is not layout")
        let other = LaTeXMacroExpander.extractDocumentMacros(from: #"\newcommand{\Drop}[2]{\item #1}"#)
        XCTAssertNil(LaTeXTransparentMacro.analyze(try XCTUnwrap(other["\\Drop"]), macros: other), "a body must show every argument")
    }

    func testMultiLineCallJoinsLinesAndHidesItsSyntax() {
        let rendered = lines(entry)
        XCTAssertEqual(
            rendered,
            [
                "(⟦‹b:open›⟧ ⟦‹i: file›⟧ ↩",
                ")",
                "⟦$\\triangleright$ ⟧ ↩",
                "Opens ⟦‹i:file›⟧. ↩",
                ""
            ]
        )
    }

    func testSeparatorStartsAnIndentedParagraph() throws {
        let text = LaTeXStyledDocument.document(preamble: preamble, body: entry)
        let (storage, _) = LaTeXStyledDocument.style(text, cursorLine: 0)
        let ns = storage.string as NSString
        let opens = ns.range(of: "Opens").location
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: opens, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.headIndent, 0)
        let firstLine = ns.lineRange(for: NSRange(location: ns.range(of: "\\ENTRY{(").location, length: 0))
        let secondLineEnd = NSMaxRange(ns.lineRange(for: NSRange(location: NSMaxRange(firstLine), length: 0))) - 1
        XCTAssertNil(
            storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: secondLineEnd, effectiveRange: nil), "the break before the separator stays")
        XCTAssertNotNil(storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: NSMaxRange(firstLine) - 1, effectiveRange: nil))
    }

    func testActiveBlockShowsItsSource() {
        let rendered = lines(entry, cursorOnBodyLine: 3)
        XCTAssertEqual(rendered[0], #"‹tt:\ENTRY›{(‹tt:\Kw›{open} ‹tt:\Arg›{"#)
        XCTAssertTrue(rendered[3].contains("‹i:% says what it does›"), rendered[3])
    }

    func testOneLineCallsUseInlineSeparators() {
        XCTAssertEqual(lines(#"\ENTRY{\Kw{a}} {b}"#), ["⟦‹b:a›⟧⟦\u{2002}$\\triangleright$ ⟧b"])
        XCTAssertEqual(lines(#"\Two{\Kw{a}} {b}"#), ["⟦‹b:a›⟧⟦\u{2003}⟧b"], "without a hint, the separator is an em space")
    }

    func testProbeStopsAtBlankLinesAndBounds() {
        let ns = "\\ENTRY{a\nb}\n{c}\n\nnext\n" as NSString
        let probe = LaTeXLiveStyler.probeMultiLineCall(lineRange: ns.lineRange(for: NSRange(location: 0, length: 0)), nsString: ns, macros: macros)
        XCTAssertEqual(probe.blockEnd, ns.range(of: "{c}\n").upperBound)
        XCTAssertEqual(probe.contextEnd, ns.range(of: "\n\n").location + 2, "the blank line that ends the window is context")

        let split = "\\ENTRY{a\n\nb} {c}\n" as NSString
        XCTAssertNil(
            LaTeXLiveStyler.probeMultiLineCall(lineRange: split.lineRange(for: NSRange(location: 0, length: 0)), nsString: split, macros: macros).blockEnd)

        XCTAssertEqual(LaTeXLiveStyler.MultiLineCallLimits.maxLines, 40)
        let near = ("\\ENTRY{a\n" + String(repeating: "x\n", count: 30) + "} {b}\n") as NSString
        XCTAssertNotNil(
            LaTeXLiveStyler.probeMultiLineCall(lineRange: near.lineRange(for: NSRange(location: 0, length: 0)), nsString: near, macros: macros).blockEnd)
        let long = ("\\ENTRY{a\n" + String(repeating: "x\n", count: 45) + "} {b}\n") as NSString
        let longProbe = LaTeXLiveStyler.probeMultiLineCall(lineRange: long.lineRange(for: NSRange(location: 0, length: 0)), nsString: long, macros: macros)
        XCTAssertNil(longProbe.blockEnd, "a call longer than the line cap keeps its source")

        let closed = "\\Kw{a} \\Arg{b}\nnext\n" as NSString
        let closedProbe = LaTeXLiveStyler.probeMultiLineCall(
            lineRange: closed.lineRange(for: NSRange(location: 0, length: 0)), nsString: closed, macros: macros)
        XCTAssertEqual(
            closedProbe, LaTeXLiveStyler.MultiLineCallProbe(blockEnd: nil, contextEnd: closed.range(of: "\n").upperBound), "a closed line reads nothing else")
    }

    func testMaskedCommentsKeepOffsets() {
        XCTAssertEqual(LaTeXLiveStyler.maskedComments("a % b\n50\\% c%"), "a    \n50\\% c ")
    }

    func testCursorAtStartOfTheNextLineLeavesTheBlockRendered() {
        let body = entry + "\nAfter"
        XCTAssertEqual(lines(body, cursorOnBodyLine: 5)[0], "(⟦‹b:open›⟧ ⟦‹i: file›⟧ ↩", "the editor restyles only when the active line changes")
    }

    func testCallWithContentAfterItsBraceJoins() {
        XCTAssertEqual(lines("\\Kw{\\Arg{a}\n  b} c"), ["⟦‹b+i:a›‹b: b›⟧ ↩", " c"])
    }

    func testStylingAnotherStorageKeepsTheSession() {
        let text = LaTeXStyledDocument.document(preamble: preamble, body: entry)
        let editor = NSTextStorage()
        let recorder = EditorPerfRecorder()
        EditorPerfScope.bind(recorder) {
            _ = LaTeXStyledDocument.style(text, cursorLine: 0, storage: editor)
            _ = LaTeXStyledDocument.style(text, cursorLine: 0)
            _ = LaTeXStyledDocument.style(text, cursorLine: 1, storage: editor)
        }
        XCTAssertGreaterThan(recorder.counters.latexBlocksReusedCount, 0, "a reference restyle of another storage must not evict the editor's blocks")
    }

    /// Restyling after an edit, with cached blocks, must equal a fresh restyle.
    func testEditsOnOtherLinesRestyleTheCall() throws {
        let cases: [(name: String, before: String, after: String)] = [
            ("close on a later line", "\\ENTRY{(\\Kw{a}\nmore\n\nnext\n", "\\ENTRY{(\\Kw{a}\nmore)} {b}\n\nnext\n"),
            ("blank line that ended the window fills", "\\ENTRY{(\\Kw{a}\nmore\n\n)} {b}\n", "\\ENTRY{(\\Kw{a}\nmore\nx\n)} {b}\n"),
            ("remove the call", "\\ENTRY{(\\Kw{a}\nmore)} {b}\nnext\n", "(\\Kw{a}\nmore)} {b}\nnext\n"),
            ("comment block meets a new comment", "% one\n\nplain\n", "% one\n\n% two\n"),
            ("block macro closes later", "\\Kw{\nword\n\nend\n", "\\Kw{\nword\n\nend}\n"),
            ("font switch above", "text\n\nmore\n", "\\itshape\n\nmore\n"),
            ("glue above a blank line changes", "\\vfill\n\nnext\n", "\\vfil\n\nnext\n"),
            ("glue below a blank line changes", "text\n\n\\vfill\n", "text\n\nwords\n")
        ]
        for (name, before, after) in cases {
            let storage = NSTextStorage()
            _ = LaTeXStyledDocument.style(LaTeXStyledDocument.document(preamble: preamble, body: before), storage: storage)
            let afterText = LaTeXStyledDocument.document(preamble: preamble, body: after)
            let incremental = LaTeXStyledDocument.style(afterText, storage: storage)
            let full = LaTeXStyledDocument.style(afterText)
            XCTAssertNil(RestyleEquivalenceOracle.firstAttributeDifference(actual: incremental.storage, expected: full.storage), name)
            XCTAssertEqual(incremental.analysis.decorations, full.analysis.decorations, name)
        }
    }
}
