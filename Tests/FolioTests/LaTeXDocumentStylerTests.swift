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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("folio_latex_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

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
            if case .latexTheoremCard(let header, let isProof, _, _) = dec.kind {
                return !isProof && header == "Theorem 1 (Main Bound)."
            }
            return false
        }
        XCTAssertTrue(hasTheoremCard)

        let hasProofCard = analysis.decorations.contains { dec in
            if case .latexTheoremCard(_, let isProof, _, _) = dec.kind {
                return isProof
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
    func testLaTeXModeFormattingActions() {
        let vm = EditorWorkspaceViewModel()
        vm.currentFileURL = URL(fileURLWithPath: "/tmp/paper.tex")
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
}
