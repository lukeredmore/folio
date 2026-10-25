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
        let expectedBaseSize = round(customTheme.baseFontSize * (12.0 / 11.0) * 10.0) / 10.0
        XCTAssertEqual(Double(pStyle?.paragraphSpacing ?? 0), Double(expectedBaseSize * 0.75), accuracy: 0.5)

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
}
