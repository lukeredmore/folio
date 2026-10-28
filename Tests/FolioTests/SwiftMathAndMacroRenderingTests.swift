import AppKit
import XCTest
@testable import Folio

final class SwiftMathAndMacroRenderingTests: XCTestCase {

    override func tearDown() {
        LaTeXMathRenderer.setDocumentMacros([:])
        super.tearDown()
    }

    func testSwiftMathNativeOpenTypeLayoutAndMatrices() {
        let simpleBox = LaTeXMathRenderer.layoutLatex(#"x + y"#, baseFontSize: 16, isDisplayStyle: true)
        XCTAssertTrue(simpleBox.usesNativeOpenTypeMath, "Valid LaTeX should use native SwiftMath OpenType layout")
        assertMathMetrics(simpleBox, width: 44, ascent: 12, descent: 4, "x + y")
        let doubleSizeBox = LaTeXMathRenderer.layoutLatex(#"x + y"#, baseFontSize: 32, isDisplayStyle: true)
        XCTAssertEqual(doubleSizeBox.width, simpleBox.width * 2, accuracy: 1, "Layout scales with the font size")

        let matrixLatex = #"""
            \begin{pmatrix}
            a_{11} & a_{12} & a_{13} \\
            a_{21} & a_{22} & a_{23} \\
            a_{31} & a_{32} & a_{33}
            \end{pmatrix}
            """#
        let matrixBox = LaTeXMathRenderer.layoutLatex(matrixLatex, baseFontSize: 16, isDisplayStyle: true)
        XCTAssertTrue(matrixBox.usesNativeOpenTypeMath)
        assertMathMetrics(matrixBox, width: 141, ascent: 35, descent: 25, "3x3 pmatrix")
        XCTAssertGreaterThan(
            matrixBox.totalHeight,
            simpleBox.totalHeight * 2.0,
            "3x3 pmatrix should be more than 2x taller than a single-line expression"
        )

        let casesLatex = #"""
            f(x) = \begin{cases}
            x^2 & \text{if } x \geq 0 \\
            -x & \text{if } x < 0
            \end{cases}
            """#
        let casesBox = LaTeXMathRenderer.layoutLatex(casesLatex, baseFontSize: 16, isDisplayStyle: true)
        XCTAssertTrue(casesBox.usesNativeOpenTypeMath)
        assertMathMetrics(casesBox, width: 184, ascent: 25, descent: 16, "cases")
    }

    func testAlignAndEquationEnvironmentNormalizationAndTags() {
        let alignLatex = #"""
            \begin{align}
            \nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \label{eq:gauss} \\
            \nabla \times \mathbf{B} &= \mu_0 \mathbf{J} + \mu_0 \varepsilon_0 \frac{\partial \mathbf{E}}{\partial t} \tag{2.1}
            \end{align}
            """#
        let alignBox = LaTeXMathRenderer.layoutLatex(alignLatex, baseFontSize: 16, isDisplayStyle: true)
        XCTAssertTrue(alignBox.usesNativeOpenTypeMath)
        XCTAssertEqual(alignBox.tag, "(2.1)")
        assertMathMetrics(alignBox, width: 196, ascent: 48, descent: 39, "two-row align")
    }

    func testParameterizedNewcommandAndDeclareMathOperatorExpansion() {
        let doc = #"""
            \newcommand{\R}{\mathbb{R}}
            \newcommand{\norm}[1]{\left\lVert #1 \right\rVert}
            \newcommand{\ip}[2]{\langle #1, #2 \rangle}
            \newcommand{\deriv}[2][x]{\frac{d #2}{d #1}}
            \DeclareMathOperator*{\argmin}{arg\,min}
            """#
        let macros = LaTeXMacroExpander.extractDocumentMacros(from: doc)
        XCTAssertEqual(macros.count, 5)
        XCTAssertTrue(LaTeXMacroExpander.isStandaloneMacroDefinitionBlock(doc))

        let (expanded, tag) = LaTeXMacroExpander.expandAndNormalize(
            #"\argmin_{x \in \R} \norm{A x - b}^2 + \ip{u}{v} + \deriv{f} + \deriv[t]{g} \tag*{*}"#,
            macros: macros
        )
        XCTAssertEqual(tag, "*")
        XCTAssertTrue(expanded.contains(#"\mathbb{R}"#))
        XCTAssertTrue(expanded.contains(#"\left\Vert A x - b \right\Vert"#))
        XCTAssertTrue(expanded.contains(#"\langle u, v \rangle"#))
        XCTAssertTrue(expanded.contains(#"\frac{d f}{d x}"#))
        XCTAssertTrue(expanded.contains(#"\frac{d g}{d t}"#))

        let source = #"\argmin_{x \in \R} \norm{A x - b}^2 + \ip{u}{v}"#
        let box = LaTeXMathRenderer.layoutLatex(source, baseFontSize: 16, isDisplayStyle: true, macros: macros)
        XCTAssertTrue(box.usesNativeOpenTypeMath)
        assertMathMetrics(box, width: 213, ascent: 20, descent: 17, "macro expression")
        let handExpanded = LaTeXMacroExpander.expandAndNormalize(source, macros: macros).0
        let expandedBox = LaTeXMathRenderer.layoutLatex(handExpanded, baseFontSize: 16, isDisplayStyle: true, macros: [:])
        assertMathMetrics(
            box, width: expandedBox.width, ascent: expandedBox.ascent, descent: expandedBox.descent,
            accuracy: 0.01, "Macros lay out the same as their expansion")
    }

    func testTallDisplayMathReservesProportionalLineHeightAndExpandsDocumentMacros() {
        let markdown = #"""
            $$
            \newcommand{\R}{\mathbb{R}}
            \newcommand{\norm}[1]{\left\lVert #1 \right\rVert}
            $$

            Inline macro usage $\norm{x} \in \R$ inside prose.

            $$
            \begin{pmatrix}
            1 & 2 & 3 \\
            4 & 5 & 6 \\
            7 & 8 & 9 \\
            10 & 11 & 12
            \end{pmatrix}
            $$

            Active cursor line at the bottom.
            """#

        let storage = NSTextStorage(string: markdown)
        let nsString = markdown as NSString
        let activeLoc = nsString.range(of: "Active cursor line").location

        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: activeLoc, length: 0),
            containerWidth: 720
        )

        let matrixLoc = nsString.range(of: "1 & 2 & 3").location
        let matrixPara = storage.attribute(.paragraphStyle, at: matrixLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(matrixPara)
        XCTAssertGreaterThan(
            matrixPara?.minimumLineHeight ?? 0,
            12.0,
            "Inactive display math block lines should reserve proportional minimumLineHeight"
        )
        XCTAssertEqual(matrixPara?.minimumLineHeight, matrixPara?.maximumLineHeight)

        let renderedBlocks = analysis.decorations.compactMap { dec -> String? in
            if case .mathBlockRendered(let latex, _, _) = dec.kind {
                return latex
            }
            return nil
        }
        XCTAssertEqual(renderedBlocks.count, 2)
        XCTAssertTrue(renderedBlocks[1].contains("\n"), "Multi-line display math should preserve line breaks")
    }

    func testSwiftMathOffscreenDrawingInFlippedContext() throws {
        let box = LaTeXMathRenderer.layoutLatex(
            #"\int_0^\infty \frac{\sin(x)}{x} \, dx = \frac{\pi}{2}"#,
            baseFontSize: 18,
            isDisplayStyle: true
        )
        XCTAssertTrue(box.usesNativeOpenTypeMath)

        let margin: CGFloat = 10
        let pixelsWide = Int(ceil(box.width + margin * 2))
        let pixelsHigh = Int(ceil(box.totalHeight + margin * 2))
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
        let bitmapContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        bitmapContext.cgContext.translateBy(x: 0, y: CGFloat(pixelsHigh))
        bitmapContext.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapContext.cgContext, flipped: true)
        box.drawBox(margin, margin + box.ascent, .black)
        NSGraphicsContext.restoreGraphicsState()

        var ink = (minX: Int.max, maxX: Int.min, minY: Int.max, maxY: Int.min)
        for y in 0..<pixelsHigh {
            for x in 0..<pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                ink = (min(ink.minX, x), max(ink.maxX, x), min(ink.minY, y), max(ink.maxY, y))
            }
        }
        // Row 0 is the top of the bitmap, so these are the flipped view's coordinates.
        XCTAssertGreaterThanOrEqual(CGFloat(ink.minX), margin - 1, "Ink starts at the drawing origin")
        XCTAssertLessThanOrEqual(CGFloat(ink.maxX), margin + box.width + 1, "Ink ends within the box width")
        XCTAssertGreaterThanOrEqual(CGFloat(ink.minY), margin - 1, "Ink starts at the top of the box, not above it")
        XCTAssertLessThanOrEqual(CGFloat(ink.maxY), margin + box.totalHeight + 1, "Ink ends at the bottom of the box")
        XCTAssertGreaterThan(CGFloat(ink.maxX - ink.minX), box.width * 0.9, "The formula fills the box width")
        XCTAssertGreaterThan(CGFloat(ink.maxY - ink.minY), box.totalHeight * 0.8, "The formula fills the box height")
    }

    func testShowcaseEquationsRenderWithNativeOpenTypeMath() {
        let preamble = #"""
            \newcommand{\R}{\mathbb{R}}
            \newcommand{\C}{\mathbb{C}}
            \newcommand{\N}{\mathbb{N}}
            \newcommand{\E}{\mathbb{E}}
            \newcommand{\Prob}{\mathbb{P}}
            \newcommand{\calL}{\mathcal{L}}
            \newcommand{\calN}{\mathcal{N}}
            \newcommand{\norm}[1]{\left\lVert #1 \right\rVert}
            \newcommand{\abs}[1]{\left\lvert #1 \right\rvert}
            \newcommand{\ip}[2]{\left\langle #1, #2 \right\rangle}
            \newcommand{\pdv}[3][]{\frac{\partial^{#1} #2}{\partial #3^{#1}}}
            \newcommand{\KL}[2]{D_{\mathrm{KL}}\left(#1 \,\middle\|\, #2\right)}
            \DeclareMathOperator*{\argmin}{arg\,min}
            \DeclareMathOperator*{\argmax}{arg\,max}
            \DeclareMathOperator{\Tr}{Tr}
            \DeclareMathOperator{\Cov}{Cov}
            """#
        let macros = LaTeXMacroExpander.extractDocumentMacros(from: preamble)

        let equations: [(latex: String, width: CGFloat, ascent: CGFloat, descent: CGFloat, tag: String?)] = [
            (#"\abs{\ip{u}{v}} \le \norm{u}_2 \norm{v}_2"#, 147, 15, 8, nil),
            (#"\norm{A}_F = \sqrt{\Tr(A^* A)}"#, 155, 25, 10, nil),
            (#"\pdv{u}{t} + \pdv[2]{u}{x} + \pdv[2]{u}{y} = 0"#, 162, 29, 17, nil),
            (
                #"\theta^* = \argmin_{\theta \in \R^d} \left\{ \frac{1}{2n} \norm{X\theta - y}_2^2 + \frac{\lambda}{2} \norm{\theta}_2^2 \right\} \tag{1}"#,
                308, 26, 19, "(1)"
            ),
            (
                #"""
                \begin{align}
                \log p_\theta(x) &= \E_{q_\phi(z \mid x)}\left[ \log \frac{p_\theta(x, z)}{q_\phi(z \mid x)} \right] + \KL{q_\phi(z \mid x)}{p_\theta(z \mid x)} \\
                &\ge \E_{q_\phi(z \mid x)}\left[ \log p_\theta(x \mid z) \right] - D_{\mathrm{KL}}\left( q_\phi(z \mid x) \parallel p(z) \right] \\
                &\equiv \calL_{\mathrm{ELBO}}(\theta, \phi; x)
                \end{align} \tag{2}
                """#.replacingOccurrences(of: #"\parallel p(z) \right]"#, with: #"\parallel p(z) \right)"#), 493, 59, 50, "(2)"
            ),
            (
                #"\zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s} = \prod_{\substack{p \in \N \\ p \text{ prime}}} \frac{1}{1 - p^{-s}} \tag{6}"#, 256, 28, 46,
                "(6)"
            ),
            (#"i\hbar \pdv{}{t}\ket{\Psi(t)} = \left( -\frac{\hbar^2}{2m}\nabla^2 + V(\hat{\mathbf{r}}, t) \right)\ket{\Psi(t)} \tag{9}"#, 338, 29, 18, "(9)")
        ]

        for eq in equations {
            let box = LaTeXMathRenderer.layoutLatex(eq.latex, baseFontSize: 16, isDisplayStyle: true, macros: macros)
            XCTAssertTrue(box.usesNativeOpenTypeMath, "Expected native OpenType math for: \(eq.latex)")
            XCTAssertEqual(box.tag, eq.tag, eq.latex)
            assertMathMetrics(box, width: eq.width, ascent: eq.ascent, descent: eq.descent, eq.latex)
        }
    }

    func testInlineMathDoesNotSplitAcrossWrappedLinesAndSuppressesSpellCheck() {
        let markdown = #"""
            $$
            \newcommand{\R}{\mathbb{R}}
            \newcommand{\C}{\mathbb{C}}
            \newcommand{\N}{\mathbb{N}}
            \newcommand{\pdv}[3][]{\frac{\partial^{#1} #2}{\partial #3^{#1}}}
            $$

            - **Parameterized & Optional-Argument Macros**: Using `\pdv` with its default order gives the first partial derivative $\pdv{u}{t}$, while passing the optional argument `[2]` produces the second partial derivative $\pdv[2]{u}{x} + \pdv[2]{u}{y} = 0$.
            - **Font Alphabets**: Compare Roman $\mathrm{d}x$, Bold $\mathbf{F} = m\mathbf{a}$, Bold-Italic $\boldsymbol{\theta}^*$, Calligraphic $\mathcal{F}\{f(t)\}$, Blackboard Bold $\R, \C, \N, \mathbb{Z}, \mathbb{Q}$, Fraktur $\mathfrak{su}(2) \oplus \mathfrak{u}(1)$.

            Active line at bottom.
            """#

        let storage = NSTextStorage(string: markdown)
        let layoutManager = WideBlockLayoutManager()
        let delegate = SoftLineBreakLayoutDelegate()
        layoutManager.delegate = delegate
        let container = WideBlockTextContainer(size: NSSize(width: 560, height: 4000))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let nsString = markdown as NSString
        let activeLoc = nsString.range(of: "Active line at bottom").location
        let analysis = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: activeLoc, length: 0),
            containerWidth: 560
        )
        layoutManager.ensureLayout(for: container)

        // Every inlineMathRendered span must lie on a single line fragment (never split mid-formula)
        let inlineMathRanges = analysis.decorations.compactMap { dec -> NSRange? in
            if case .inlineMathRendered(_, let range, _, _) = dec.kind {
                return range
            }
            return nil
        }
        XCTAssertGreaterThanOrEqual(inlineMathRanges.count, 8)
        for mathRange in inlineMathRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: mathRange, actualCharacterRange: nil)
            var firstFragRange = NSRange()
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: &firstFragRange)
            XCTAssertTrue(
                NSLocationInRange(NSMaxRange(glyphRange) - 1, firstFragRange),
                "Inline math span \(nsString.substring(with: mathRange)) must not wrap across two line fragments"
            )
            XCTAssertTrue(
                WideBlockLayoutManager.shouldSuppressSpellCheck(in: storage, range: mathRange),
                "Spellcheck must be suppressed inside inline math span"
            )
        }

        // Verify that WideBlockLayoutManager blocks asynchronous .spellingState temporary attributes on math & code
        let codeRange = nsString.range(of: #"`\pdv`"#)
        layoutManager.addTemporaryAttribute(.spellingState, value: 1, forCharacterRange: codeRange)
        XCTAssertNil(
            layoutManager.temporaryAttribute(.spellingState, atCharacterIndex: codeRange.location + 1, effectiveRange: nil),
            "WideBlockLayoutManager must reject .spellingState inside inline code"
        )
        if let firstMath = inlineMathRanges.first {
            layoutManager.addTemporaryAttribute(.spellingState, value: 1, forCharacterRange: firstMath)
            XCTAssertNil(
                layoutManager.temporaryAttribute(.spellingState, atCharacterIndex: firstMath.location + 1, effectiveRange: nil),
                "WideBlockLayoutManager must reject .spellingState inside inline math"
            )
        }
    }

    func testBoxedMathAndPracticeTestConstructs() {
        let boxedEquations: [(latex: String, width: CGFloat, ascent: CGFloat, descent: CGFloat)] = [
            (#"\frac{126}{189}=\frac{42}{63}=\frac{14}{21}=\boxed{\frac23}."#, 169.5, 29.5, 17.5),
            (#"\boxed{\text{infinitely many solutions}}."#, 223.5, 17.5, 7.5),
            (#"3\left(\frac52\right)=\boxed{\frac{15}{2}=7\frac12\text{ cups}}."#, 203.5, 29.5, 16.5),
            (#"|4-9|-2|-3|=5-2(3)=\boxed{-1}."#, 287.5, 16.5, 6.7)
        ]
        for eq in boxedEquations {
            let box = LaTeXMathRenderer.layoutLatex(eq.latex, baseFontSize: 16, isDisplayStyle: true)
            XCTAssertTrue(box.usesNativeOpenTypeMath, "Expected SwiftMath native layout for \(eq.latex)")
            assertMathMetrics(box, width: eq.width, ascent: eq.ascent, descent: eq.descent, eq.latex)
        }

        let tex = #"""
            \documentclass[11pt]{article}
            \begin{document}
            \begin{center}
            {\Large\textbf{MAT 121 Practice Test}}\\[4pt]
            \end{center}
            \sectiontitle{Rational Numbers (Section 1.2)}
            \workspace[0.75in]{
            {\color{answercolor}\textbf{Solution.}}
            \[
            \frac{126}{189}=\boxed{\frac23}.
            \]
            }
            Active line
            \end{document}
            """#
        let storage = NSTextStorage(string: tex)
        let activeLoc = (tex as NSString).range(of: "Active line").location
        let analysis = LaTeXLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: activeLoc, length: 0),
            containerWidth: 680
        )
        XCTAssertTrue(analysis.headings.contains { $0.title == "Rational Numbers (Section 1.2)" })
        let titleLoc = (tex as NSString).range(of: "MAT 121 Practice Test").location
        let pStyle = storage.attribute(.paragraphStyle, at: titleLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(pStyle?.alignment, .center)
    }

    func testProseMacrosCommentFoldingAndLeadingCommentsBeforeDocumentClass() {
        let tex = #"""
            % Compile with XeLaTeX.
            \documentclass[12pt]{article}
            \newcommand{\sendername}{Luke W. Redmore}
            \newcommand{\originaltoll}{\$5.60}
            \begin{document}
            % Option 1 draft
            % \sendername
            \textbf{Re: Violation \originaltoll{}} under ``Grounds''
            Active line
            \end{document}
            """#
        let storage = NSTextStorage(string: tex)
        let activeLoc = (tex as NSString).range(of: "Active line").location
        let analysis = LaTeXLiveStyler.applyStyles(
            to: storage, theme: .daylight, sourceCodeMode: false, focusMode: false,
            selectedRange: NSRange(location: activeLoc, length: 0), containerWidth: 680
        )
        XCTAssertTrue(
            analysis.decorations.contains {
                if case .latexPreambleCard = $0.kind { return true }; return false
            })
        XCTAssertTrue(
            analysis.decorations.contains {
                if case .latexInlineText("$5.60", _, _, _) = $0.kind { return true }; return false
            })
        XCTAssertTrue(
            analysis.decorations.contains {
                if case .latexInlineText("“", _, _, _) = $0.kind { return true }; return false
            })
    }
}
