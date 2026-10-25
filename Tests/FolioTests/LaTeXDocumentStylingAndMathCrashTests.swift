import AppKit
import XCTest
@testable import Folio

final class LaTeXDocumentStylingAndMathCrashTests: XCTestCase {

    func testPunctuationSpaceUnaryMinusDoesNotCrashSwiftMath() {
        let expressions = [
            #"-4x^2y,\quad 7xy^2,\quad 9x^2y,\quad -3xy^2,\quad 5x^2,\quad -2x^2y"#,
            #"\boxed{-4x^2y,\ 9x^2y,\ -2x^2y}"#,
            #"\boxed{7xy^2,\ -3xy^2}."#,
            #"a,\ -b,\quad +c,\; -d"#,
            #"\begin{aligned} x &= 1,\ -2 \\ y &= \boxed{3,\ -4} \end{aligned}"#
        ]
        for expr in expressions {
            let box = LaTeXMathRenderer.layoutLatex(expr, baseFontSize: 16.0, isDisplayStyle: true)
            XCTAssertGreaterThan(box.width, 10.0, "Expected non-empty layout for: \(expr)")
            XCTAssertGreaterThan(box.totalHeight, 6.0, "Expected positive height for: \(expr)")
        }
    }

    func testCodeSpecifiedStylingOverridesThemeAndFallsBackWhenAbsent() {
        let styledTeX = """
        \\documentclass[12pt,letterpaper]{article}
        \\usepackage{fontspec}
        \\usepackage{setspace}
        \\setmainfont{Times New Roman}
        \\setstretch{1.08}
        \\setlength{\\parindent}{0pt}
        \\setlength{\\parskip}{0.75em}
        \\definecolor{AnswerColor}{RGB}{0,90,180}
        \\begin{document}
        \\section*{Section Header}
        Body paragraph text in Times New Roman.

        {\\color{AnswerColor}\\textbf{Solution:} Worked step.}
        \\end{document}
        """

        var customTheme = EditorTheme.daylight
        customTheme.bodyFontFamily = "Avenir Next"
        customTheme.headingFontFamily = "Avenir Next"

        let storage = NSTextStorage(string: styledTeX)
        _ = LaTeXLiveStyler.applyStyles(
            to: storage,
            theme: customTheme,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 700
        )

        let ns = styledTeX as NSString
        let bodyRange = ns.range(of: "Body paragraph text")
        XCTAssertNotEqual(bodyRange.location, NSNotFound)
        let bodyFont = storage.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(bodyFont)
        XCTAssertTrue(
            bodyFont?.familyName?.contains("Times") == true || bodyFont?.fontName.contains("Times") == true,
            "Expected Times New Roman from \\setmainfont, got \(String(describing: bodyFont?.fontName))"
        )

        let pStyle = storage.attribute(.paragraphStyle, at: bodyRange.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(pStyle)
        XCTAssertEqual(Double(pStyle?.lineHeightMultiple ?? 0), 1.08, accuracy: 0.01)
        XCTAssertEqual(Double(pStyle?.firstLineHeadIndent ?? -1), 0.0, accuracy: 0.01)
        XCTAssertEqual(Double(pStyle?.paragraphSpacing ?? -1), 0.0, accuracy: 0.01)

        let bodyLineRange = ns.lineRange(for: bodyRange)
        let blankLineStyle = storage.attribute(.paragraphStyle, at: NSMaxRange(bodyLineRange), effectiveRange: nil) as? NSParagraphStyle
        let expectedBaseSize = round(customTheme.baseFontSize * (12.0 / 11.0) * 10.0) / 10.0
        XCTAssertEqual(Double(blankLineStyle?.minimumLineHeight ?? 0), Double(expectedBaseSize * 0.75), accuracy: 0.5)

        let solRange = ns.range(of: "Worked step.")
        XCTAssertNotEqual(solRange.location, NSNotFound)
        let solColor = storage.attribute(.foregroundColor, at: solRange.location, effectiveRange: nil) as? NSColor
        let srgb = solColor?.usingColorSpace(.sRGB)
        XCTAssertNotNil(srgb)
        XCTAssertEqual(Double(srgb?.redComponent ?? 1.0), 0.0, accuracy: 0.02)
        XCTAssertEqual(Double(srgb?.greenComponent ?? 0.0), 90.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(Double(srgb?.blueComponent ?? 0.0), 180.0 / 255.0, accuracy: 0.02)

        // Fallback test: when no font/stretch/spacing is specified in code, theme styling is used
        let unstyledTeX = """
        \\documentclass{article}
        \\begin{document}
        Fallback theme paragraph text.
        \\end{document}
        """
        let fallbackStorage = NSTextStorage(string: unstyledTeX)
        _ = LaTeXLiveStyler.applyStyles(
            to: fallbackStorage,
            theme: customTheme,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 700
        )
        let fbRange = (unstyledTeX as NSString).range(of: "Fallback theme")
        let fbFont = fallbackStorage.attribute(.font, at: fbRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(fbFont?.familyName, customTheme.bodyFont(size: customTheme.baseFontSize).familyName)
    }

    func testPlainTexAndPlain2TexRenderWithoutCrash() throws {
        let candidatePaths = [
            "/Users/lukeredmore/Downloads/plain.tex",
            "/Users/lukeredmore/Downloads/plain-2.tex"
        ]
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let storage = NSTextStorage(string: text)
            let analysis = LaTeXLiveStyler.applyStyles(
                to: storage,
                theme: .daylight,
                sourceCodeMode: false,
                prettyMode: true,
                focusMode: false,
                selectedRange: NSRange(location: 0, length: 0),
                containerWidth: 760,
                fileURL: URL(fileURLWithPath: path)
            )
            XCTAssertFalse(analysis.decorations.isEmpty, "Expected decorations for \(path)")
        }
    }

    @MainActor
    func testLaTeXPrintViewCollapsesPreambleAndCommentsAndRespectsSingleSpacedAddressBlocks() throws {
        var commentBlock = ""
        for i in 1...110 {
            commentBlock += "% Comment line \(i)\n"
        }
        let letterTeX = """
        \\documentclass[12pt]{article}
        \\usepackage[margin=1in]{geometry}
        \\usepackage{setspace}
        \\setstretch{1.05}
        \\setlength{\\parindent}{0pt}
        \\setlength{\\parskip}{0.75em}
        \\newcommand{\\letterdate}{August 21, 2026}
        \\newcommand{\\sendername}{Luke Redmore}
        \\newcommand{\\senderaddress}{1109 N. Clayton St.\\\\Wilmington, DE 19806}
        \\newcommand{\\senderemail}{lukeredmore@gmail.com}
        \\begin{document}

        \(commentBlock)
        \\letterdate

        \\vspace{1em}
        \\sendername\\\\
        \\senderaddress\\\\
        \\senderemail

        \\vspace{1em}
        Delaware Department of Transportation\\\\
        Toll Operations / E-ZPass Customer Service Center\\\\
        P.O. Box 52598\\\\
        New Castle, DE 19720
        \\end{document}
        """

        let vm = EditorWorkspaceViewModel()
        vm.markdownText = letterTeX
        let printView = vm.makePrintView()
        guard let lm = printView.layoutManager else {
            XCTFail("Expected layoutManager on printView")
            return
        }
        let ns = printView.string as NSString
        let dateLoc = ns.range(of: "\\letterdate").location
        XCTAssertNotEqual(dateLoc, NSNotFound)
        let dateGlyph = lm.glyphIndexForCharacter(at: dateLoc)
        let dateRect = lm.lineFragmentRect(forGlyphAt: dateGlyph, effectiveRange: nil)
        XCTAssertLessThan(dateRect.minY, 8.0, "Expected \\letterdate near top of Page 1, got y=\(dateRect.minY)")

        let recipientLine1 = ns.range(of: "Delaware Department of Transportation").location
        let recipientLine2 = ns.range(of: "Toll Operations").location
        let r1Rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: recipientLine1), effectiveRange: nil)
        let r2Rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: recipientLine2), effectiveRange: nil)
        XCTAssertLessThan(r2Rect.minY - r1Rect.minY, 19.0, "Expected single-spaced address lines, got delta=\(r2Rect.minY - r1Rect.minY)")
    }

    func testLaTeXConditionalsAndWorkspaceMacroColoringAndCollapsing() {
        func makeWorksheetTeX(answersTrue: Bool) -> String {
            let toggle = answersTrue ? "\\answerstrue % <-- CHANGE THIS TO \\answersfalse" : "\\answersfalse"
            return """
            \\documentclass[11pt]{article}
            \\definecolor{AnswerColor}{RGB}{0,90,180}
            \\newif\\ifanswers
            \(toggle)
            \\newcommand{\\workspace}[2][1.05in]{%
                \\ifanswers
                    \\vspace{2pt}
                    {\\color{AnswerColor}\\textbf{Solution:} #2}
                    \\vspace{8pt}
                \\else
                    \\vspace{#1}
                \\fi
            }
            \\begin{document}
            \\begin{center}
            {\\LARGE\\bfseries Simplifying Expressions}\\\\[4pt]
            \\ifanswers
            {\\normalsize\\color{AnswerColor}\\textbf{ANSWER KEY -- Worked Solutions}}
            \\else
            {\\normalsize Practice Version}
            \\fi
            \\end{center}
            \\workspace[0.75in]{
            Group by matching variable parts:
            \\[
            (-4 + 9 - 2)x^2y = \\boxed{3x^2y}
            \\]
            }
            \\end{document}
            """
        }

        let trueTeX = makeWorksheetTeX(answersTrue: true)
        let trueStorage = NSTextStorage(string: trueTeX)
        let trueAnalysis = LaTeXLiveStyler.applyStyles(
            to: trueStorage,
            theme: .daylight,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 700
        )
        let trueNS = trueTeX as NSString
        let answerKeyLoc = trueNS.range(of: "ANSWER KEY").location
        let practiceLoc = trueNS.range(of: "Practice Version").location
        XCTAssertNil(trueStorage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: answerKeyLoc, effectiveRange: nil))
        XCTAssertEqual(trueStorage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: practiceLoc, effectiveRange: nil) as? Bool, true)
        let keyColor = (trueStorage.attribute(.foregroundColor, at: answerKeyLoc, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        XCTAssertEqual(Double(keyColor?.blueComponent ?? 0), 180.0 / 255.0, accuracy: 0.02)

        let groupByLoc = trueNS.range(of: "Group by matching").location
        let mathOpenLoc = trueNS.range(of: "(-4 + 9 - 2)").location
        let wsColor = (trueStorage.attribute(MarkdownLiveStyler.customColorAttributeKey, at: groupByLoc, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        let mathColor = (trueStorage.attribute(MarkdownLiveStyler.customColorAttributeKey, at: mathOpenLoc, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        XCTAssertEqual(Double(wsColor?.blueComponent ?? 0), 180.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(Double(mathColor?.blueComponent ?? 0), 180.0 / 255.0, accuracy: 0.02)
        XCTAssertTrue(trueAnalysis.decorations.contains(where: {
            if case .latexInlineText(let text, _, _, _) = $0.kind {
                return text == "Solution:"
            }
            return false
        }))

        let falseTeX = makeWorksheetTeX(answersTrue: false)
        let falseStorage = NSTextStorage(string: falseTeX)
        let falseAnalysis = LaTeXLiveStyler.applyStyles(
            to: falseStorage,
            theme: .daylight,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 700
        )
        let falseNS = falseTeX as NSString
        XCTAssertEqual(falseStorage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: falseNS.range(of: "ANSWER KEY").location, effectiveRange: nil) as? Bool, true)
        XCTAssertNil(falseStorage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: falseNS.range(of: "Practice Version").location, effectiveRange: nil))
        let wsOpenLoc = falseNS.range(of: "\\workspace[0.75in]{").location
        let wsPStyle = falseStorage.attribute(.paragraphStyle, at: wsOpenLoc, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(Double(wsPStyle?.minimumLineHeight ?? 0), 54.0, accuracy: 0.5)
        XCTAssertFalse(falseAnalysis.decorations.contains(where: {
            if case .mathBlockRendered = $0.kind { return true }
            return false
        }))
    }
}
