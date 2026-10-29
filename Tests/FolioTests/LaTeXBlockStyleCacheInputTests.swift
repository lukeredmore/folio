import AppKit
import XCTest
@testable import Folio

/// The LaTeX block style cache reuses a block only when every input of its styling is the same.
/// After each change, restyling the same storage must equal a full restyle of a new storage.
@MainActor
final class LaTeXBlockStyleCacheInputTests: XCTestCase {
    private let preamble = #"""
        \def\ENTRY#1 #2 {\item{}#1\hfill#2}
        \newcommand{\Kw}[1]{\textbf{#1}}
        \newcommand{\Arg}[1]{\textit{#1}}
        """#

    private let body = #"""
        See \ref{sec:b} and \ref{sec:c}.

        \ENTRY{(\Kw{open} \Arg{
            file})}
        {
          Opens \Arg{file}.
        }

        \section{A}
        Plain words.

        \section{B}\label{sec:b}
        More words.

        \section{C}\label{sec:c}
        Last words.
        """#

    private var text: String { LaTeXStyledDocument.document(preamble: preamble, body: body) }

    private func parameters(
        width: CGFloat = 900,
        theme: EditorTheme = .daylight,
        typography: EditorTypographySettings = EditorTheme.daylight.typography,
        focusMode: Bool = false
    ) -> MarkdownStyleParameters {
        MarkdownStyleParameters(
            theme: theme, typography: typography, sourceCodeMode: false, focusMode: focusMode, containerWidth: width,
            prettyMode: true, baseDirectoryURL: nil, textAlignment: .natural, fileURL: nil
        )
    }

    /// Restyles `storage` and fails with the first difference from a full restyle of a new storage.
    private func assertRestyleMatchesFullRestyle(
        _ storage: NSTextStorage,
        _ parameters: MarkdownStyleParameters,
        cursorBefore marker: String = "Last words",
        _ message: String,
        line: UInt = #line
    ) {
        let cursor = NSRange(location: (storage.string as NSString).range(of: marker).location, length: 0)
        let actual = MarkdownLiveStyler.applyStyles(to: storage, parameters: parameters, selectedRange: cursor)
        let reference = NSTextStorage(string: storage.string)
        let expected = MarkdownLiveStyler.applyStyles(to: reference, parameters: parameters, selectedRange: cursor)
        if let difference = RestyleEquivalenceOracle.firstAttributeDifference(actual: storage, expected: reference) {
            XCTFail("\(message): \(difference)", line: line)
        }
        XCTAssertEqual(actual.decorations, expected.decorations, "\(message): decorations differ", line: line)
        XCTAssertEqual(actual.headings, expected.headings, "\(message): headings differ", line: line)
    }

    private func insert(_ string: String, before marker: String, in storage: NSTextStorage) {
        let location = (storage.string as NSString).range(of: marker).location
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: string)
    }

    func testContentWidthChangeRestylesCachedBlocks() {
        let storage = NSTextStorage(string: text)
        assertRestyleMatchesFullRestyle(storage, parameters(width: 900), "first restyle")
        assertRestyleMatchesFullRestyle(storage, parameters(width: 646), "narrower content")
        insert("x", before: "Last words", in: storage)
        assertRestyleMatchesFullRestyle(storage, parameters(width: 646), "edit after the call")
        assertRestyleMatchesFullRestyle(storage, parameters(width: 663), "wider content, no edit")
        assertRestyleMatchesFullRestyle(storage, parameters(width: 663), cursorBefore: "Plain words", "cursor move")
    }

    func testThemeTypographyAndFocusChangesRestyleCachedBlocks() {
        let storage = NSTextStorage(string: text)
        var typography = EditorTheme.daylight.typography
        assertRestyleMatchesFullRestyle(storage, parameters(), "first restyle")
        let dark = EditorTheme.builtInThemes.first { $0.isDark } ?? .daylight
        assertRestyleMatchesFullRestyle(storage, parameters(theme: dark), "theme change")
        typography.fontSizeScale = 1.2
        typography.lineHeightMultiple = 1.5
        assertRestyleMatchesFullRestyle(storage, parameters(theme: dark, typography: typography), "typography change")
        insert("x", before: "Last words", in: storage)
        assertRestyleMatchesFullRestyle(storage, parameters(theme: dark, typography: typography, focusMode: true), "focus mode with an edit")
    }

    /// A reference before an edit shows the number and target of a label after it.
    func testReferenceBeforeAnEditFollowsTheLabel() {
        let storage = NSTextStorage(string: text)
        assertRestyleMatchesFullRestyle(storage, parameters(), "first restyle")
        insert("Moved words.\n", before: "\\section{B}", in: storage)
        assertRestyleMatchesFullRestyle(storage, parameters(), "text inserted before the label")
        insert("\\section{New}\n", before: "\\section{B}", in: storage)
        assertRestyleMatchesFullRestyle(storage, parameters(), "section inserted before the label")
        let starred = (storage.string as NSString).range(of: "\\section{New}")
        storage.replaceCharacters(in: starred, with: "\\section*{New}")
        assertRestyleMatchesFullRestyle(storage, parameters(), "section made unnumbered")
    }
}
