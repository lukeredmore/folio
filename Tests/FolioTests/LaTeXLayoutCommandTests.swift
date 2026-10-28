import AppKit
import XCTest
@testable import Folio

/// Commands that print nothing: lines that hold only them fold, font switches style the text
/// after them, and definitions in the body never expand the name they define.
@MainActor
final class LaTeXLayoutCommandTests: XCTestCase {
    private func analyze(_ code: String, macros: [String: LaTeXMacroDefinition] = [:]) -> LaTeXLayoutLine {
        LaTeXLayoutLine.analyze(code, macros: macros)
    }

    func testLayoutOnlyLines() {
        let lines = [
            #"\rmfamily\mdseries\itshape\fontsize{20}{0}\selectfont"#,
            #"\hfill\vfill\vspace*{15mm}\hspace{2pt}\kern-1pt\penalty-5"#,
            #"\clearpage\newpage\pagestyle{empty}\thispagestyle{plain}\markboth{A}{B}"#,
            #"\begin{titlepage}"#, #"\begin{minipage}[t]{\titlepagewidth}"#, #"\end{minipage}\\"#, #"\begin{multicols}{2}"#,
            #"\newlength{\titlepagewidth}"#, #"\setlength{\titlepagewidth}{8cm}"#, #"\advance\oddsidemargin by 1.5mm"#,
            #"\renewcommand{\rmdefault}{ptm}"#, #"\def\x#1{#1}"#, #"\let\a=\b"#, #"\ITtab=3em"#, #"\arraycolsep0pt"#,
            #"{"#, #"}"#, #"\newcount\currentpage"#
        ]
        for line in lines {
            XCTAssertTrue(analyze(line).isLayoutOnly, line)
        }
    }

    func testContentLines() {
        for line in [
            #"Quick Reference\index{CLQR}\\"#, #"\hfill Common\/\\[2mm]"#, #"\begin{center}"#, #"\section{A}"#, #"\maketitle"#,
            #"\fontsize{300}{0}\selectfont{\color{gray}cl\/}"#, #"\unknown"#, #"\newcommand{\x}{"#, #"\item x"#
        ] {
            XCTAssertFalse(analyze(line).isLayoutOnly, line)
        }
    }

    func testRulesAreDrawnUnlessEmpty() {
        XCTAssertTrue(analyze(#"\rule[3mm]{\textwidth}{1.5mm}\\"#).drawsRule)
        XCTAssertTrue(analyze(#"\hrule"#).drawsRule)
        XCTAssertFalse(analyze(#"\rule{0pt}{0pt}\clearpage"#).drawsRule)
    }

    func testUserMacrosThatPrintNothingAreLayout() {
        let macros = LaTeXMacroExpander.extractDocumentMacros(
            from: #"\newcommand{\Hook}{\clearpage}\newcommand{\Empty}{}\newcommand{\Spin}{\Spin}\newcommand{\T}{T}"#)
        XCTAssertTrue(analyze(#"\Hook % paper hook"#, macros: macros).isLayoutOnly)
        XCTAssertTrue(analyze(#"\Empty{}"#, macros: macros).isLayoutOnly)
        XCTAssertFalse(analyze(#"\Spin"#, macros: macros).isLayoutOnly, "a recursive macro stops at the nesting cap")
        XCTAssertFalse(analyze(#"\T"#, macros: macros).isLayoutOnly)
    }

    func testEffectsTrackGroupsAndEnvironments() {
        XCTAssertEqual(analyze(#"{\itshape x} \bfseries"#).effects, [.declaration(.named("bfseries"))])
        XCTAssertEqual(analyze(#"\begin{minipage}{3cm}{\sffamily"#).effects, [.beginEnvironment("minipage"), .openGroup, .declaration(.named("sffamily"))])
        XCTAssertEqual(analyze(#"}\end{minipage}"#).effects, [.closeGroup, .endEnvironment("minipage")])
        XCTAssertEqual(analyze(#"\fontsize{20}{0}\selectfont\centering"#).effects, [.declaration(.fontSize(20)), .declaration(.alignment(.center))])
    }

    func testFlowStateScopesDeclarations() {
        var flow = LaTeXFlowState()
        flow.apply([.beginEnvironment("titlepage"), .declaration(.named("itshape")), .declaration(.fontSize(20))], documentFontSize: 10)
        XCTAssertTrue(flow.style.italic)
        XCTAssertEqual(flow.style.sizeScale, 2.0)
        flow.apply([.beginEnvironment("flushright"), .declaration(.named("upshape"))], documentFontSize: 10)
        XCTAssertFalse(flow.style.italic)
        XCTAssertEqual(flow.alignment, .right)
        flow.apply([.declaration(.fontSize(300))], documentFontSize: 10)
        XCTAssertEqual(flow.style.sizeScale, 3.0, "sizes are capped")
        flow.apply([.endEnvironment("titlepage")], documentFontSize: 10)
        XCTAssertTrue(flow.isDefault, "ending an outer environment closes the inner ones")
        flow.apply([.closeGroup, .endEnvironment("missing")], documentFontSize: 10)
        XCTAssertEqual(flow, LaTeXFlowState(), "unmatched ends are ignored")
    }

    private let preamble = #"""
        \newcommand{\rmdefault}{cmr}
        \newcommand{\Kw}[1]{\textbf{#1}}
        """#

    private func bodyLines(_ body: String) -> [String] {
        let start = LaTeXStyledDocument.bodyStartLine(preamble: preamble)
        let all = LaTeXStyledDocument.renderedLines(LaTeXStyledDocument.document(preamble: preamble, body: body), cursorLine: 0)
        return Array(all[start..<(start + body.components(separatedBy: "\n").count)])
    }

    func testRenewcommandInBodyDoesNotExpandTheDefinedName() {
        XCTAssertEqual(bodyLines(#"\renewcommand{\rmdefault}{ptm} %% title font"#), [""], "a definition line folds")
        XCTAssertEqual(bodyLines(#"Serif \renewcommand{\rmdefault}{ptm}text."#), ["Serif text."])
    }

    func testFontSwitchLinesStyleTheFollowingLines() throws {
        let body = "\\begin{titlepage}\n\\itshape\\fontsize{20}{0}\\selectfont\nBig title\n\\end{titlepage}\nAfter"
        XCTAssertEqual(bodyLines(body), ["", "", "‹i:Big title›", "", "After"])
        let text = LaTeXStyledDocument.document(preamble: preamble, body: body)
        let (storage, _) = LaTeXStyledDocument.style(text, cursorLine: 0)
        let ns = storage.string as NSString
        let big = try XCTUnwrap(storage.attribute(.font, at: ns.range(of: "Big").location, effectiveRange: nil) as? NSFont)
        let after = try XCTUnwrap(storage.attribute(.font, at: ns.range(of: "After").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(big.pointSize, after.pointSize * 2, accuracy: 0.1, "\\fontsize{20} is twice the 10pt class size")
    }

    func testInlineLayoutCommandsAndGroupsHide() {
        XCTAssertEqual(bodyLines(#"Printed by \Kw{us}\hfill{\itshape in color}\/, \copyright\ 2024."#), ["Printed by ⟦‹b:us›⟧‹i:in color›, ⟦©⟧ 2024."])
        XCTAssertEqual(bodyLines(#"\section*{\contentsname}"#), ["⟦Contents⟧"])
        // `\,` reserves a thin space that draws nothing, so the dump shows no characters for it.
        XCTAssertEqual(bodyLines(#"A\,b and \qquad c"#), ["Ab and ⟦\u{2003}\u{2003}⟧c"])
    }

    func testBuiltinBoxesShowTheirContent() {
        XCTAssertEqual(bodyLines(#"\makebox[\textwidth][l]{Boxed} and \raisebox{1mm}[0pt][0pt]{up}"#), ["Boxed and up"])
        XCTAssertEqual(LaTeXProseMacroExpander.render(#"a\penalty-5 b"#, macros: [:]), [.text("a b", LaTeXProseStyle())])
    }

    func testUnknownGraysStayGray() {
        let index = LaTeXDocumentIndex()
        let gray = index.resolveColor(named: "frontcovergray", fallbackTheme: .daylight)
        XCTAssertNotEqual(gray, EditorTheme.daylight.linkNSColor)
        let rgb = gray.usingColorSpace(.sRGB)
        XCTAssertEqual(rgb?.redComponent ?? 0, rgb?.blueComponent ?? 1, accuracy: 0.05)
    }

    func testRuleLinesDrawARule() {
        let text = LaTeXStyledDocument.document(preamble: preamble, body: #"\rule[3mm]{\textwidth}{1.5mm}\\"#)
        let (_, analysis) = LaTeXStyledDocument.style(text, cursorLine: 0)
        XCTAssertTrue(analysis.decorations.contains { if case .horizontalRule = $0.kind { return true } else { return false } })
    }

    func testDocumentNamesExpand() {
        XCTAssertEqual(LaTeXProseMacroExpander.builtinText(forCommand: "contentsname"), "Contents")
        XCTAssertEqual(LaTeXProseMacroExpander.builtinText(forCommand: "indexname"), "Index")
        XCTAssertEqual(LaTeXProseMacroExpander.builtinText(forCommand: "refname"), "References")
        XCTAssertEqual(LaTeXProseMacroExpander.builtinText(forCommand: "figurename"), "Figure")
        XCTAssertEqual(LaTeXProseMacroExpander.builtinText(forCommand: "tablename"), "Table")
        XCTAssertNil(LaTeXProseMacroExpander.builtinText(forCommand: "hfill"))
        XCTAssertEqual(LaTeXProseMacroExpander.render(#"\figurename~1"#, macros: [:]), [.text("Figure\u{00A0}1", LaTeXProseStyle())])
    }

    func testTextMacrosInsideMathUseMathFonts() {
        let macros = LaTeXMacroExpander.extractDocumentMacros(
            from: #"""
                \newcommand{\VAR}[1]{\text{{\fontfamily{cmr}\fontshape{it}\selectfont#1\/}}}
                \newcommand{\NEV}[1]{\text{{$\widehat{#1}$}}}
                \newcommand{\N}{N}
                \newcommand{\P}[1]{{#1}\text{${}^{{\raisebox{.5ex}[0pt][0pt]{\tiny\sffamily\makebox[0pt][l]{\hspace{-.6ex}P}}*}}$}}
                """#)
        XCTAssertEqual(
            LaTeXProseMacroExpander.expandCall(source: #"\NEV{\VAR{a b}}"#, macros: macros)?.segments,
            [.math(#"\widehat{{\mathit{a\ b}}}"#, LaTeXProseStyle())])
        XCTAssertEqual(LaTeXProseMacroExpander.render(#"$\N + 1$"#, macros: macros), [.math(#"\N + 1"#, LaTeXProseStyle())], "math macros stay")
        let progn = LaTeXProseMacroExpander.expandCall(source: #"\P{x}"#, macros: macros)?.segments.last
        XCTAssertEqual(progn, .math(#"{}^{{{\text{P}}*}}"#, LaTeXProseStyle()), "text boxes in math keep their content")
    }
}
