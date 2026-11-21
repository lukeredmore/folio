import AppKit
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

@MainActor
final class LaTeXBasicTeXRenderingTests: XCTestCase {
    private func isCollapsed(_ storage: NSTextStorage, substring: String) -> Bool {
        let ns = storage.string as NSString
        let range = ns.range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing substring: \(substring)")
        guard range.location != NSNotFound else { return false }
        return (storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: range.location, effectiveRange: nil) as? Bool) == true
    }

    private func isFoldedLine(_ storage: NSTextStorage, containing substring: String) -> Bool {
        let ns = storage.string as NSString
        let range = ns.range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing line: \(substring)")
        guard range.location != NSNotFound else { return false }
        let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let maxHeight = style?.maximumLineHeight ?? 0
        return maxHeight > 0 && maxHeight < 8
    }

    private func font(in storage: NSTextStorage, substring: String) throws -> NSFont {
        let ns = storage.string as NSString
        let range = ns.range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing substring: \(substring)")
        return try XCTUnwrap(storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    func testNewfontfamilyAndNewfontfaceBracedAndUnbraced() throws {
        let tex = #"""
            \documentclass{article}
            \usepackage{fontspec}
            \setmainfont{Helvetica Neue}
            \newfontfamily\name{Helvetica Neue}[Scale={1.8}, UprightFont={*-bold}]
            \newfontfamily\info{Helvetica Neue}[Scale={0.92}]
            \newfontfamily\spaced{Helvetica Neue}[Scale={0.92}, LetterSpace={10}]
            \newfontfamily\alt[Scale={1.25}]{Georgia}
            \newfontface\heavyface{Helvetica Neue Bold}
            \newfontfamily\bower{Bower}[Scale={1.85}, UprightFont={*-bold}]
            \newfontfamily\mck{McKinsey Sans}[Scale={1.2},UprightFont={*-light}]
            \begin{document}
            {\name Luke Redmore}\\
            {\info
            Binghamton, NY |
            \href{https://example.com}{link.example.org}}
            Normal body text.
            {\spaced Section Label}
            {\alt Leading Options}
            {\heavyface Face Bold}
            \bower Here is some text!!\\
            \mck And here is some more
            \end{document}
            """#

        let (storage, _) = LaTeXStyledDocument.style(tex)

        // Single-line braced \name hides syntax and applies 1.8x bold scale
        XCTAssertTrue(isCollapsed(storage, substring: "{\\name "))
        let nameCloseLoc = (storage.string as NSString).range(of: "Luke Redmore}").upperBound - 1
        XCTAssertEqual(
            storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: nameCloseLoc, effectiveRange: nil) as? Bool,
            true
        )
        XCTAssertFalse(isCollapsed(storage, substring: "Luke Redmore"))
        let nameFont = try font(in: storage, substring: "Luke Redmore")
        let normalFont = try font(in: storage, substring: "Normal body text.")
        XCTAssertTrue(NSFontManager.shared.traits(of: nameFont).contains(.boldFontMask))
        XCTAssertEqual(nameFont.pointSize, normalFont.pointSize * 1.8, accuracy: 0.5)

        // Multi-line {\info ...} folds opening line, scales interior lines, hides closing brace, reverts after
        XCTAssertTrue(isFoldedLine(storage, containing: "{\\info"))
        let infoLineFont = try font(in: storage, substring: "Binghamton, NY")
        let infoHrefFont = try font(in: storage, substring: "link.example.org")
        XCTAssertEqual(infoLineFont.pointSize, normalFont.pointSize * 0.92, accuracy: 0.5)
        XCTAssertEqual(infoHrefFont.pointSize, normalFont.pointSize * 0.92, accuracy: 0.5)
        let closeBraceLoc = (storage.string as NSString).range(of: "{link.example.org}}").upperBound - 1
        XCTAssertEqual(
            storage.attribute(MarkdownLiveStyler.collapsedTokenAttributeKey, at: closeBraceLoc, effectiveRange: nil) as? Bool,
            true
        )
        XCTAssertEqual(normalFont.pointSize, EditorTheme.daylight.baseFontSize, accuracy: 0.5)

        // LetterSpace={10} applies 0.10 em kerning
        let spacedLoc = (storage.string as NSString).range(of: "Section Label").location
        let spacedKern = try XCTUnwrap(storage.attribute(.kern, at: spacedLoc, effectiveRange: nil) as? CGFloat)
        let spacedFont = try font(in: storage, substring: "Section Label")
        XCTAssertEqual(spacedKern, spacedFont.pointSize * 0.10, accuracy: 0.2)

        // Leading [opts]{Font} and \newfontface
        let altFont = try font(in: storage, substring: "Leading Options")
        XCTAssertEqual(altFont.pointSize, normalFont.pointSize * 1.25, accuracy: 0.5)
        let faceFont = try font(in: storage, substring: "Face Bold")
        XCTAssertTrue(NSFontManager.shared.traits(of: faceFont).contains(.boldFontMask))

        // Unbraced flow switches carry through lines and override cleanly
        XCTAssertTrue(isCollapsed(storage, substring: "\\bower "))
        XCTAssertTrue(isCollapsed(storage, substring: "\\mck "))
        let bowerFont = try font(in: storage, substring: "Here is some text!!")
        let mckFont = try font(in: storage, substring: "And here is some more")
        XCTAssertTrue(NSFontManager.shared.traits(of: bowerFont).contains(.boldFontMask))
        XCTAssertEqual(bowerFont.pointSize, normalFont.pointSize * 1.85, accuracy: 0.5)
        XCTAssertFalse(NSFontManager.shared.traits(of: mckFont).contains(.boldFontMask))
        XCTAssertEqual(mckFont.pointSize, normalFont.pointSize * 1.2, accuracy: 0.5)
    }

    func testZeroArgumentDeclarationMacros() throws {
        let preamble = #"""
            \newcommand{\subhead}{\bfseries}
            \def\italicsw{\itshape}
            """#
        let body = #"""
            {\subhead Duke University} plain
            {\italicsw
            Italic line one
            Italic line two}
            Back to normal
            """#
        let doc = LaTeXStyledDocument.document(preamble: preamble, body: body)
        let (storage, _) = LaTeXStyledDocument.style(doc, cursorLine: 0)

        XCTAssertTrue(isCollapsed(storage, substring: "{\\subhead "))
        let subheadFont = try font(in: storage, substring: "Duke University")
        let plainFont = try font(in: storage, substring: "plain")
        XCTAssertTrue(NSFontManager.shared.traits(of: subheadFont).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: plainFont).contains(.boldFontMask))

        XCTAssertTrue(isFoldedLine(storage, containing: "{\\italicsw"))
        let line1Font = try font(in: storage, substring: "Italic line one")
        let line2Font = try font(in: storage, substring: "Italic line two")
        let backFont = try font(in: storage, substring: "Back to normal")
        XCTAssertTrue(NSFontManager.shared.traits(of: line1Font).contains(.italicFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: line2Font).contains(.italicFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: backFont).contains(.italicFontMask))
    }

    func testClassicTwoLetterSwitchesAndSpacedStackedGroups() throws {
        let body = #"""
            {\bf bold} {\it italic} {\tt mono} {\sc caps} {\sf sans} {\rm roman} {\sl slanted} { \bf\large stacked}
            """#
        let doc = LaTeXStyledDocument.document(preamble: "", body: body)
        let (storage, _) = LaTeXStyledDocument.style(doc, cursorLine: 0)
        let manager = NSFontManager.shared

        XCTAssertTrue(manager.traits(of: try font(in: storage, substring: "bold")).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: try font(in: storage, substring: "italic")).contains(.italicFontMask))
        XCTAssertTrue(try font(in: storage, substring: "mono").isFixedPitch)
        XCTAssertTrue(manager.traits(of: try font(in: storage, substring: "slanted")).contains(.italicFontMask))

        let romanFont = try font(in: storage, substring: "roman")
        let capsFont = try font(in: storage, substring: "caps")
        XCTAssertLessThan(capsFont.pointSize, romanFont.pointSize)

        let stackedFont = try font(in: storage, substring: "stacked")
        XCTAssertTrue(manager.traits(of: stackedFont).contains(.boldFontMask))
        XCTAssertGreaterThan(stackedFont.pointSize, romanFont.pointSize)
        XCTAssertTrue(isCollapsed(storage, substring: "{ \\bf"))
    }

    func testWrapperEnvironmentsClassicDefLetAndTabCollapse() {
        let preamble = #"""
            \def\changemargin#1#2{\list{}{\rightmargin#2\leftmargin#1}\item[]}
            \let\endchangemargin=\endlist
            """#
        let body = """
            \\begin{spacing}{1}
            \t\tIndented line.
            \\end{spacing}
            \\begin{changemargin}{0.5in}{0.5in}
            Margin body.
            \\end{changemargin}
            """
        let doc = LaTeXStyledDocument.document(preamble: preamble, body: body)
        let (storage, _) = LaTeXStyledDocument.style(doc, cursorLine: 0)

        XCTAssertTrue(isFoldedLine(storage, containing: "\\begin{spacing}{1}"))
        XCTAssertTrue(isFoldedLine(storage, containing: "\\end{spacing}"))
        XCTAssertTrue(isFoldedLine(storage, containing: "\\begin{changemargin}{0.5in}{0.5in}"))
        XCTAssertTrue(isFoldedLine(storage, containing: "\\end{changemargin}"))
        XCTAssertTrue(isCollapsed(storage, substring: "\t\t"))
        XCTAssertFalse(isCollapsed(storage, substring: "Indented line."))
        XCTAssertFalse(isCollapsed(storage, substring: "Margin body."))
    }

    func testCenterEnvironmentWithSameLineContent() throws {
        let preamble = #"\newfontfamily\name{Helvetica Neue}[Scale={1.5}, UprightFont={*-bold}]"#
        let body = #"""
            \begin{center} {\name Header Name}\\
            Second Line
            \end{center}
            \begin{center} Single Line Center \end{center}
            """#
        let doc = LaTeXStyledDocument.document(preamble: preamble, body: body)
        let (storage, _) = LaTeXStyledDocument.style(doc, cursorLine: 0)

        XCTAssertFalse(isFoldedLine(storage, containing: "Header Name"))
        XCTAssertFalse(isCollapsed(storage, substring: "Header Name"))
        let hdrColor = storage.attribute(.foregroundColor, at: (storage.string as NSString).range(of: "Header Name").location, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(hdrColor, NSColor.clear)
        let hdrFont = try font(in: storage, substring: "Header Name")
        XCTAssertTrue(NSFontManager.shared.traits(of: hdrFont).contains(.boldFontMask))

        XCTAssertFalse(isFoldedLine(storage, containing: "Single Line Center"))
        XCTAssertFalse(isCollapsed(storage, substring: "Single Line Center"))
        XCTAssertTrue(isCollapsed(storage, substring: "\\begin{center} Single"))
        XCTAssertTrue(isCollapsed(storage, substring: " \\end{center}"))
    }

    func testProseLigaturesAndMonospacePreservation() {
        let body = #"""
            Summer 2021 -- 2022 --- note~1 ---- \texttt{--flag ~} {\tt --mono} \url{https://example.com/~u--v} $a - -b$
            """#
        let doc = LaTeXStyledDocument.document(preamble: "", body: body)
        let (storage, analysis) = LaTeXStyledDocument.style(doc, cursorLine: 0)

        let inlineTexts = analysis.decorations.compactMap { dec -> String? in
            if case .latexInlineText(let text, _, _, _) = dec.kind { return text }
            return nil
        }
        XCTAssertEqual(inlineTexts, ["–", "—", "\u{00A0}"])
        XCTAssertFalse(isCollapsed(storage, substring: "----"))
        XCTAssertFalse(isCollapsed(storage, substring: "--flag"))
        XCTAssertFalse(isCollapsed(storage, substring: "--mono"))
    }

    func testHFillSingleLineLayoutAndRightAlignment() throws {
        let preamble = #"""
            \newfontfamily\subhead{Helvetica Neue}[UprightFont={*-Bold}]
            \newfontfamily\detail{Helvetica Neue}[Scale={0.92}]
            """#
        let body = #"{\subhead Duke University} \hfill {\detail Durham, NC}\\"#
        let tex = LaTeXStyledDocument.document(preamble: preamble, body: body)
        let containerWidth: CGFloat = 720
        let storage = NSTextStorage(string: tex)
        let layoutManager = WideBlockLayoutManager()
        let delegate = SoftLineBreakLayoutDelegate()
        layoutManager.delegate = delegate
        storage.addLayoutManager(layoutManager)
        let container = WideBlockTextContainer(containerSize: NSSize(width: containerWidth, height: 2000))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        _ = LaTeXLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: containerWidth
        )
        layoutManager.ensureLayout(for: container)

        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: ns.range(of: "Duke University"))
        let lineGlyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineFragmentCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: lineGlyphs) { _, _, _, _, _ in
            lineFragmentCount += 1
        }
        XCTAssertEqual(lineFragmentCount, 1, "\\hfill line must fit on a single line fragment")

        let durhamCharLoc = ns.range(of: "Durham, NC").location
        let durhamGlyph = layoutManager.glyphIndexForCharacter(at: durhamCharLoc)
        let durhamPoint = layoutManager.location(forGlyphAt: durhamGlyph)
        XCTAssertGreaterThan(durhamPoint.x, containerWidth * 0.6, "Right-side text after \\hfill should align near the right margin")
    }

    func testExtendedStyleCommandsPackageFontsizeAndIncludegraphicsWithLineBreak() throws {
        let tex = #"""
            \documentclass{article}
            \usepackage[fontsize=12pt]{fontsize}
            \begin{document}
            \textrm{rm} \textsf{sf} \textsl{sl} \textup{up} \textmd{md} \textnormal{norm} \uline{under} x\textsuperscript{2} y\textsubscript{i} \emph{outer \emph{inner}}
            \includegraphics[scale=0.5]{signature.png}\\
            \end{document}
            """#
        let storage = NSTextStorage(string: tex)
        let docIndex = LaTeXDocumentIndexer.buildIndex(string: tex, nsString: storage.string as NSString)
        XCTAssertEqual(docIndex.documentStyle.documentFontSizePt, 12.0)

        let analysis = LaTeXLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 720
        )
        let ns = storage.string as NSString
        let manager = NSFontManager.shared

        XCTAssertTrue(manager.traits(of: try font(in: storage, substring: "sl}")).contains(.italicFontMask))
        XCTAssertFalse(manager.traits(of: try font(in: storage, substring: "up}")).contains(.italicFontMask))
        XCTAssertFalse(manager.traits(of: try font(in: storage, substring: "md}")).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: try font(in: storage, substring: "outer")).contains(.italicFontMask))
        XCTAssertFalse(manager.traits(of: try font(in: storage, substring: "inner")).contains(.italicFontMask))

        let underLoc = ns.range(of: "under}").location
        XCTAssertEqual(storage.attribute(.underlineStyle, at: underLoc, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)

        let supLoc = ns.range(of: "2}").location
        let subLoc = ns.range(of: "i}").location
        XCTAssertGreaterThan((storage.attribute(.baselineOffset, at: supLoc, effectiveRange: nil) as? CGFloat) ?? 0, 0)
        XCTAssertLessThan((storage.attribute(.baselineOffset, at: subLoc, effectiveRange: nil) as? CGFloat) ?? 0, 0)

        let hasImage = analysis.decorations.contains { dec in
            if case .imageRendered(let url, _, _, _, _, _, _) = dec.kind {
                return url == "signature.png"
            }
            return false
        }
        XCTAssertTrue(hasImage)
    }

    func testResumeDocumentIncrementalRestyleEquivalence() {
        let initial = #"""
            \documentclass{article}
            \usepackage{fontspec}
            \setmainfont{Helvetica Neue}
            \usepackage[fontsize=12pt]{fontsize}
            \usepackage{setspace}
            \newfontfamily\name{Helvetica Neue}[Scale={1.8}, UprightFont={*-bold}]
            \newfontfamily\subhead{Helvetica Neue}[UprightFont={*-Bold}]
            \newfontfamily\detail{Helvetica Neue}[Scale={0.92}]
            \newfontfamily\info{Helvetica Neue}[Scale={0.92}]
            \newenvironment{itemize*}{\begin{spacing}{0}\begin{itemize}}{\end{itemize}\end{spacing}}
            \begin{document}
            \begin{center}
            {\name Luke Redmore}\\
            {\info
            Binghamton, NY |
            \href{mailto:luke@example.com}{luke@example.com}}
            \rule{\textwidth}{.4pt}
            \end{center}
            \section*{Education}
            {\subhead Duke University} \hfill {\detail Durham, NC}\\
            \begin{spacing}{1}
            	Major: Computer Science\\
            \end{spacing}
            \begin{itemize*}
            	\item Built system in Summer 2021 -- 2022 --- zero downtime~1
            \end{itemize*}
            \end{document}
            """#

        let edits: [String] = [
            initial,
            initial.replacingOccurrences(of: "Durham, NC", with: "Durham, North Carolina"),
            initial.replacingOccurrences(of: "Binghamton, NY |", with: "New York, NY |"),
            initial.replacingOccurrences(of: "Major: Computer Science", with: #"Major: {\bf Computer} Science"#)
        ]

        let storage = NSTextStorage()
        for (stepIdx, text) in edits.enumerated() {
            for cursorLine in [0, 11, 14, 18, 22] {
                let incremental = LaTeXStyledDocument.style(text, cursorLine: cursorLine, storage: storage)
                let full = LaTeXStyledDocument.style(text, cursorLine: cursorLine)
                XCTAssertNil(
                    RestyleEquivalenceOracle.firstAttributeDifference(actual: incremental.storage, expected: full.storage),
                    "step \(stepIdx) cursorLine \(cursorLine)"
                )
                XCTAssertNil(
                    RestyleEquivalenceOracle.firstDifference(
                        "decorations",
                        actual: incremental.analysis.decorations,
                        expected: full.analysis.decorations,
                        text: text
                    ),
                    "step \(stepIdx) cursorLine \(cursorLine)"
                )
            }
        }
    }
}
