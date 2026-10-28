import AppKit
import XCTest
@testable import Folio

final class LaTeXDocumentStylerTests: XCTestCase {

    func testWorkspaceFileNodeRecognizesTexAndBibExtensions() {
        let now = Date()
        let texURL = URL(fileURLWithPath: "/tmp/paper.tex")
        let bibURL = URL(fileURLWithPath: "/tmp/refs.bib")
        let mdURL = URL(fileURLWithPath: "/tmp/notes.md")

        let texNode = WorkspaceFileNode(url: texURL, name: "paper.tex", isDirectory: false, modificationDate: now, creationDate: now, children: nil)
        let bibNode = WorkspaceFileNode(url: bibURL, name: "refs.bib", isDirectory: false, modificationDate: now, creationDate: now, children: nil)
        let mdNode = WorkspaceFileNode(url: mdURL, name: "notes.md", isDirectory: false, modificationDate: now, creationDate: now, children: nil)

        XCTAssertTrue(texNode.isLaTeXFile)
        XCTAssertTrue(texNode.isSupportedDocumentFile)
        XCTAssertTrue(bibNode.isBibTeXFile)
        XCTAssertTrue(bibNode.isSupportedDocumentFile)
        XCTAssertTrue(mdNode.isMarkdownFile)

        XCTAssertEqual(LaTeXLiveStyler.documentKind(for: "", fileURL: texURL), .latex)
        XCTAssertEqual(LaTeXLiveStyler.documentKind(for: "", fileURL: bibURL), .bibtex)
        XCTAssertEqual(LaTeXLiveStyler.documentKind(for: "\\documentclass{article}\n\\begin{document}", fileURL: nil), .latex)
    }

    func testCollapsiblePreambleAndSectionNumbering() {
        let tex = """
        \\documentclass[11pt]{article}
        \\usepackage{amsmath,amssymb}
        \\newcommand{\\R}{\\mathbb{R}}
        \\begin{document}
        \\section{Introduction}\\label{sec:intro}
        Hello $\\R^n$ in \\autoref{sec:methods}.
        \\subsection{Background}
        More prose.
        \\section{Methods}\\label{sec:methods}
        Done.
        \\end{document}
        """
        let storage = NSTextStorage(string: tex)
        let cursorAtEnd = NSRange(location: (tex as NSString).length - 5, length: 0)

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: cursorAtEnd,
            fileURL: URL(fileURLWithPath: "/tmp/test.tex")
        )

        // Headings should be extracted with section numbers
        XCTAssertEqual(analysis.headings.count, 3)
        XCTAssertEqual(analysis.headings[0].title, "1 Introduction")
        XCTAssertEqual(analysis.headings[1].title, "1.1 Background")
        XCTAssertEqual(analysis.headings[2].title, "2 Methods")

        // Preamble card decoration should be emitted when cursor is outside preamble
        let hasPreambleCard = analysis.decorations.contains { dec in
            if case .latexPreambleCard(let title, let subtitle, _, _) = dec.kind {
                return title.contains("article") && subtitle.contains("packages")
            }
            return false
        }
        XCTAssertTrue(hasPreambleCard, "Expected collapsible .latexPreambleCard when cursor is outside preamble")

        // Cross-reference \autoref{sec:methods} should resolve to "Section 2" pill
        let hasResolvedAutoref = analysis.decorations.contains { dec in
            if case .latexInlinePill(let label, _, _, _, _, _, let isCitation, _) = dec.kind {
                return !isCitation && label == "Section 2"
            }
            return false
        }
        XCTAssertTrue(hasResolvedAutoref, "Expected \\autoref{sec:methods} to resolve to 'Section 2'")

        // Moving cursor to index 0 (inside preamble) should expand preamble into codeFence lines
        let activePreambleAnalysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            fileURL: URL(fileURLWithPath: "/tmp/test.tex")
        )
        let hasPreambleCardWhenActive = activePreambleAnalysis.decorations.contains { dec in
            if case .latexPreambleCard = dec.kind { return true }
            return false
        }
        XCTAssertFalse(hasPreambleCardWhenActive, "Active preamble should expand for editing")
    }

    func testTheoremsEquationsAndExternalBibTeXCitations() throws {
        let tempDir = try makeTemporaryDirectory("folio_latex_test")

        let bibContent = """
        @article{vaswani2017,
          author = {Vaswani, Ashish and Shazeer, Noam},
          title = {Attention Is All You Need},
          year = {2017}
        }
        """
        let bibURL = tempDir.appendingPathComponent("refs.bib")
        try bibContent.write(to: bibURL, atomically: true, encoding: .utf8)

        let tex = """
        \\documentclass{article}
        \\begin{document}
        \\begin{theorem}[Main Bound]\\label{thm:main}
        For all $x$, we have
        \\end{theorem}
        \\begin{equation}\\label{eq:energy}
        E = mc^2
        \\end{equation}
        \\begin{proof}
        Immediate from \\eqref{eq:energy} and \\cite{vaswani2017}.
        \\end{proof}
        \\bibliography{refs}
        \\end{document}
        """
        let texURL = tempDir.appendingPathComponent("main.tex")
        let storage = NSTextStorage(string: tex)
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: (tex as NSString).length, length: 0),
            baseDirectoryURL: tempDir,
            fileURL: texURL
        )

        let hasTheoremCard = analysis.decorations.contains { dec in
            if case .latexTheoremCard(let header, let isProof, let showHeader, _, _) = dec.kind {
                return !isProof && showHeader && header == "Theorem 1 (Main Bound)."
            }
            return false
        }
        XCTAssertTrue(hasTheoremCard)

        let hasProofCard = analysis.decorations.contains { dec in
            if case .latexTheoremCard(let header, let isProof, let showHeader, _, _) = dec.kind {
                return isProof && showHeader && header == "Proof."
            }
            return false
        }
        XCTAssertTrue(hasProofCard)

        let hasEqNumber = analysis.decorations.contains { dec in
            if case .latexEquationNumber(let number, _, _) = dec.kind {
                return number == "(1)"
            }
            return false
        }
        XCTAssertTrue(hasEqNumber)

        let hasEqRefPill = analysis.decorations.contains { dec in
            if case .latexInlinePill(let label, _, _, _, _, _, let isCitation, _) = dec.kind {
                return !isCitation && label == "(1)"
            }
            return false
        }
        XCTAssertTrue(hasEqRefPill)

        let hasCitationPill = analysis.decorations.contains { dec in
            if case .latexInlinePill(let label, _, _, _, _, _, let isCitation, _) = dec.kind {
                return isCitation && label == "[Vaswani et al., 2017]"
            }
            return false
        }
        XCTAssertTrue(hasCitationPill)
    }

    @MainActor
    func testLaTeXModeFormattingActions() throws {
        let vm = makeIsolatedViewModel()
        vm.currentFileURL = try makeTemporaryDirectory().appendingPathComponent("paper.tex")
        vm.markdownText = "Hello world"

        let textStorage = NSTextStorage(string: "Hello world")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 600, height: 800))
        layoutManager.addTextContainer(textContainer)
        let tv = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), textContainer: textContainer)
        vm.activeTextView = tv

        tv.setSelectedRange(NSRange(location: 0, length: 5))
        vm.applyInlineFormatting(prefix: "**", suffix: "**", placeholder: "bold")
        XCTAssertEqual(tv.string, "\\textbf{Hello} world")

        tv.setSelectedRange(NSRange(location: 0, length: 0))
        vm.setHeadingLevel(2)
        XCTAssertEqual(tv.string, "\\subsection{\\textbf{Hello} world}")
    }

    func testFocusedTheoremBodyAndEscapedTokensAndArgminOperator() {
        let tex = """
        \\documentclass{article}
        \\DeclareMathOperator*{\\argmin}{arg\\,min}
        \\begin{document}
        \\title{Native \\LaTeX{} Paper}
        \\begin{definition}[Inner Product]
        Let $x \\in \\mathbb{R}$.
        \\end{definition}
        \\begin{itemize}
          \\item \\textbf{Preamble \\& Macros:} Fold \\texttt{\\textbackslash usepackage} cleanly.
        \\end{itemize}
        \\end{document}
        """
        let ns = tex as NSString
        let macros = LaTeXMacroExpander.extractDocumentMacros(from: tex)
        XCTAssertEqual(macros["\\argmin"]?.operatorText, "arg min")

        let storage = NSTextStorage(string: tex)
        let bodyCursor = ns.range(of: "Let $x").location + 2
        let bodyAnalysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: bodyCursor, length: 0),
            fileURL: URL(fileURLWithPath: "/tmp/paper.tex")
        )
        // When cursor is on the body line inside definition, the card header remains visible and \begin{definition} stays folded
        let bodyCardShowsHeader = bodyAnalysis.decorations.contains { dec in
            if case .latexTheoremCard(let hdr, _, let showHeader, _, _) = dec.kind {
                return showHeader && hdr == "Definition 1 (Inner Product)."
            }
            return false
        }
        XCTAssertTrue(bodyCardShowsHeader)

        // When cursor is directly on \begin{definition}, showHeader becomes false so revealed source never overlaps
        let beginCursor = ns.range(of: "\\begin{definition}").location + 2
        let beginAnalysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: beginCursor, length: 0),
            fileURL: URL(fileURLWithPath: "/tmp/paper.tex")
        )
        let beginCardHidesHeader = beginAnalysis.decorations.contains { dec in
            if case .latexTheoremCard(_, _, let showHeader, _, _) = dec.kind {
                return !showHeader
            }
            return false
        }
        XCTAssertTrue(beginCardHidesHeader)

        // Inactive \LaTeX{}, \&, and \textbackslash fold their control tokens
        let latexSlashLoc = ns.range(of: "\\LaTeX{}").location
        let ampSlashLoc = ns.range(of: "\\&").location
        let textbackslashWordLoc = ns.range(of: "textbackslash ").location
        XCTAssertEqual(storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: latexSlashLoc, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: ampSlashLoc, effectiveRange: nil) as? Bool, true)
        XCTAssertEqual(storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: textbackslashWordLoc, effectiveRange: nil) as? Bool, true)
    }

    func testSourceCodeModeRoundtripRestoresLaTeXAndMarkdownLayoutCleanly() {
        let tex = """
        \\documentclass[11pt]{article}
        \\usepackage{amsmath}
        \\begin{document}
        \\section{Variational Principles}
        First line of soft-wrapped paragraph
        second line of soft-wrapped paragraph.
        \\begin{equation}
        \\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}
        \\end{equation}
        \\end{document}
        """
        let ns = tex as NSString
        let storage = NSTextStorage(string: tex)
        let layoutManager = WideBlockLayoutManager()
        let delegate = SoftLineBreakLayoutDelegate()
        layoutManager.delegate = delegate
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(containerSize: NSSize(width: 600, height: 2000))
        layoutManager.addTextContainer(container)

        let caret = NSRange(location: ns.length, length: 0)
        let texURL = URL(fileURLWithPath: "/tmp/roundtrip.tex")

        // 1. Initial WYSIWYG pass
        let initial = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: caret,
            fileURL: texURL
        )
        layoutManager.ensureLayout(for: container)
        let sectionCmdLoc = ns.range(of: "\\section{").location
        let eqBodyLoc = ns.range(of: "\\int_0").location
        let initialUsedRect = layoutManager.usedRect(for: container)
        XCTAssertLessThanOrEqual((storage.attribute(.font, at: sectionCmdLoc, effectiveRange: nil) as? NSFont)?.pointSize ?? 99, 0.2)
        XCTAssertEqual((storage.attribute(.foregroundColor, at: eqBodyLoc, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 1.0, 0.0, accuracy: 0.01)
        XCTAssertFalse(initial.decorations.isEmpty)

        // 2. Enter Source Code Mode
        let sourcePass = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: true,
            focusMode: false,
            selectedRange: caret,
            fileURL: texURL
        )
        layoutManager.ensureLayout(for: container)
        XCTAssertTrue(sourcePass.decorations.isEmpty)
        XCTAssertGreaterThan((storage.attribute(.font, at: sectionCmdLoc, effectiveRange: nil) as? NSFont)?.pointSize ?? 0, 10)
        XCTAssertGreaterThan((storage.attribute(.foregroundColor, at: eqBodyLoc, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 0, 0.5)

        // 3. Immediately Exit Source Code Mode -> must not reuse stale cache or leave overlaid source fonts
        let restored = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: caret,
            fileURL: texURL
        )
        layoutManager.ensureLayout(for: container)
        let restoredUsedRect = layoutManager.usedRect(for: container)
        XCTAssertLessThanOrEqual(
            (storage.attribute(.font, at: sectionCmdLoc, effectiveRange: nil) as? NSFont)?.pointSize ?? 99,
            0.2,
            "Exiting source code mode must refold \\section{ instead of leaving 15pt source font overlaid"
        )
        XCTAssertEqual(
            (storage.attribute(.foregroundColor, at: eqBodyLoc, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 1.0,
            0.0,
            accuracy: 0.01,
            "Exiting source code mode must hide equation source lines instead of drawing raw TeX over rendered math"
        )
        XCTAssertEqual(restored.decorations.count, initial.decorations.count)
        XCTAssertEqual(restoredUsedRect.height, initialUsedRect.height, accuracy: 2.0)
    }
}
