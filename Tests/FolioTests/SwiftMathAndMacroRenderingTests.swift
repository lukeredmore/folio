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
}
