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
        XCTAssertGreaterThan(simpleBox.width, 20)

        let matrixLatex = #"""
        \begin{pmatrix}
        a_{11} & a_{12} & a_{13} \\
        a_{21} & a_{22} & a_{23} \\
        a_{31} & a_{32} & a_{33}
        \end{pmatrix}
        """#
        let matrixBox = LaTeXMathRenderer.layoutLatex(matrixLatex, baseFontSize: 16, isDisplayStyle: true)
        XCTAssertTrue(matrixBox.usesNativeOpenTypeMath)
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
        XCTAssertGreaterThan(casesBox.totalHeight, simpleBox.totalHeight * 1.5)
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
        XCTAssertGreaterThan(alignBox.totalHeight, 42)
        XCTAssertGreaterThan(alignBox.width, 120)
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

        let box = LaTeXMathRenderer.layoutLatex(
            #"\argmin_{x \in \R} \norm{A x - b}^2 + \ip{u}{v}"#,
            baseFontSize: 16,
            isDisplayStyle: true,
            macros: macros
        )
        XCTAssertTrue(box.usesNativeOpenTypeMath)
        XCTAssertGreaterThan(box.width, 100)
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

    func testSwiftMathOffscreenDrawingInFlippedContext() {
        let box = LaTeXMathRenderer.layoutLatex(
            #"\int_0^\infty \frac{\sin(x)}{x} \, dx = \frac{\pi}{2}"#,
            baseFontSize: 18,
            isDisplayStyle: true
        )
        XCTAssertTrue(box.usesNativeOpenTypeMath)

        let imgSize = NSSize(width: ceil(box.width) + 20, height: ceil(box.totalHeight) + 20)
        let image = NSImage(size: imgSize, flipped: true) { _ in
            box.drawBox(10, 10 + box.ascent, .black)
            return true
        }
        XCTAssertNotNil(image.tiffRepresentation)
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

        let equations: [String] = [
            #"\abs{\ip{u}{v}} \le \norm{u}_2 \norm{v}_2"#,
            #"\norm{A}_F = \sqrt{\Tr(A^* A)}"#,
            #"\pdv{u}{t} + \pdv[2]{u}{x} + \pdv[2]{u}{y} = 0"#,
            #"\theta^* = \argmin_{\theta \in \R^d} \left\{ \frac{1}{2n} \norm{X\theta - y}_2^2 + \frac{\lambda}{2} \norm{\theta}_2^2 \right\} \tag{1}"#,
            #"""
            \begin{align}
            \log p_\theta(x) &= \E_{q_\phi(z \mid x)}\left[ \log \frac{p_\theta(x, z)}{q_\phi(z \mid x)} \right] + \KL{q_\phi(z \mid x)}{p_\theta(z \mid x)} \\
            &\ge \E_{q_\phi(z \mid x)}\left[ \log p_\theta(x \mid z) \right] - D_{\mathrm{KL}}\left( q_\phi(z \mid x) \parallel p(z) \right] \\
            &\equiv \calL_{\mathrm{ELBO}}(\theta, \phi; x)
            \end{align} \tag{2}
            """#.replacingOccurrences(of: #"\parallel p(z) \right]"#, with: #"\parallel p(z) \right)"#),
            #"\zeta(s) = \sum_{n=1}^{\infty} \frac{1}{n^s} = \prod_{\substack{p \in \N \\ p \text{ prime}}} \frac{1}{1 - p^{-s}} \tag{6}"#,
            #"i\hbar \pdv{}{t}\ket{\Psi(t)} = \left( -\frac{\hbar^2}{2m}\nabla^2 + V(\hat{\mathbf{r}}, t) \right)\ket{\Psi(t)} \tag{9}"#,
        ]

        for eq in equations {
            let box = LaTeXMathRenderer.layoutLatex(eq, baseFontSize: 16, isDisplayStyle: true, macros: macros)
            XCTAssertTrue(box.usesNativeOpenTypeMath, "Expected native OpenType math for: \(eq)")
            XCTAssertGreaterThan(box.width, 20)
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
        let boxedEquations = [
            #"\frac{126}{189}=\frac{42}{63}=\frac{14}{21}=\boxed{\frac23}."#,
            #"\boxed{\text{infinitely many solutions}}."#,
            #"3\left(\frac52\right)=\boxed{\frac{15}{2}=7\frac12\text{ cups}}."#,
            #"|4-9|-2|-3|=5-2(3)=\boxed{-1}."#,
        ]
        for eq in boxedEquations {
            let box = LaTeXMathRenderer.layoutLatex(eq, baseFontSize: 16, isDisplayStyle: true)
            XCTAssertTrue(box.usesNativeOpenTypeMath, "Expected SwiftMath native layout for \(eq)")
            XCTAssertGreaterThan(box.width, 30)
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
}
