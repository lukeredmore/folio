import AppKit
import XCTest
@testable import Folio

@MainActor
final class SoftLineBreakTests: XCTestCase {

    private let listSample = """
    # Beds

    - North Bed: a raised bed with drip irrigation, and a trellis for climbing
      beans that depends on morning sun. The trellis supports the peas in spring and the
      `pole-beans` rotation.
    - Herb Spiral: the basil, thyme, and oregano plantings.

    Plain paragraph line one
    line two\("  ")
    line three after a hard break
    """

    private func style(_ text: String, cursor: Int) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: cursor, length: 0)
        )
        return storage
    }

    private func newlineLocation(after marker: String, in text: String) -> Int {
        let ns = text as NSString
        let r = ns.range(of: marker)
        XCTAssertNotEqual(r.location, NSNotFound, marker)
        return ns.range(of: "\n", options: [], range: NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r))).location
    }

    private func isSoftBreak(_ storage: NSTextStorage, at location: Int) -> Bool {
        storage.attribute(MarkdownLiveStyler.softLineBreakAttributeKey, at: location, effectiveRange: nil) != nil
    }

    func testInactiveListItemNewlinesAreSoftBreaks() {
        let storage = style(listSample, cursor: 0)
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "trellis for climbing", in: listSample)))
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "spring and the", in: listSample)))
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "rotation.", in: listSample)),
                       "The newline that ends a list item is a block boundary")
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "# Beds", in: listSample)))
    }

    func testHardLineBreakIsKept() {
        let storage = style(listSample, cursor: 0)
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "line one", in: listSample)))
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "line two  ", in: listSample)))
    }

    func testActiveParagraphStaysJoined() {
        let cursor = (listSample as NSString).range(of: "beans that").location
        let storage = style(listSample, cursor: cursor)
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "trellis for climbing", in: listSample)),
                      "Entering a paragraph must not add visual line breaks")
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "spring and the", in: listSample)))
        let indentFont = storage.attribute(.font, at: newlineLocation(after: "trellis for climbing", in: listSample) + 1, effectiveRange: nil) as? NSFont
        XCTAssertLessThanOrEqual(indentFont?.pointSize ?? 99, 0.2, "Continuation indentation stays hidden in the active paragraph")
    }

    func testReturnInsideParagraphStartsNewParagraph() {
        final class RestyleDelegate: NSObject, NSTextViewDelegate {
            func textDidChange(_ notification: Notification) {
                guard let tv = notification.object as? NSTextView, let storage = tv.textStorage else { return }
                _ = MarkdownLiveStyler.applyStyles(to: storage, theme: .daylight, sourceCodeMode: false, focusMode: false, selectedRange: tv.selectedRange())
            }
        }
        let textView = HybridMarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let delegate = RestyleDelegate()
        textView.delegate = delegate
        textView.string = "alpha beta gamma\n\n# End"
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "alpha \n\nbeta gamma\n\n# End")

        textView.string = "alpha beta\n\n# End"
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "alpha beta\n\n\n# End", "Return at the end of a paragraph inserts one newline")
    }

    func testSoftBreaksJoinLinesInLayout() {
        let text = "alpha beta\ngamma delta\nepsilon"
        // Put the cursor in a different block so the paragraph is inactive.
        let withTrailer = NSTextStorage(string: text + "\n\n# Heading")
        _ = MarkdownLiveStyler.applyStyles(
            to: withTrailer,
            theme: .daylight,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: (withTrailer.string as NSString).length, length: 0)
        )

        let layoutManager = NSLayoutManager()
        let delegate = SoftLineBreakLayoutDelegate()
        layoutManager.delegate = delegate
        withTrailer.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        let paragraphGlyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: (text as NSString).length),
            actualCharacterRange: nil
        )
        var fragments = 0
        var glyph = paragraphGlyphs.location
        while glyph < NSMaxRange(paragraphGlyphs) {
            var fragmentRange = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentRange)
            fragments += 1
            glyph = NSMaxRange(fragmentRange)
        }
        XCTAssertEqual(fragments, 1, "Three source lines of one paragraph lay out as one visual line")
    }

    func testInlineSpansAcrossSoftLineBreaksRenderAsOneSpan() {
        let text = "- Copy the beds to your [own\n  layouts](https://example.com/layouts) and keep **bold\n  words** together.\n\n# End"
        let storage = style(text, cursor: (text as NSString).length)
        let ns = text as NSString

        let underline = storage.attribute(.underlineStyle, at: ns.range(of: "layouts]").location, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue, "Link label on the second source line is styled as a link")
        let openBracketFont = storage.attribute(.font, at: ns.range(of: "[own").location, effectiveRange: nil) as? NSFont
        XCTAssertLessThanOrEqual(openBracketFont?.pointSize ?? 99, 0.2, "Link syntax is folded")

        let boldFont = storage.attribute(.font, at: ns.range(of: "words**").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "Bold span that crosses a soft break is bold")
    }

    func testReferenceLinkAcrossSoftLineBreakIsStyled() {
        let text = "See the [reference\nlink][ref] here.\n\n[ref]: https://example.com/ref\n\n# End"
        let storage = style(text, cursor: (text as NSString).length)
        let ns = text as NSString
        let underline = storage.attribute(.underlineStyle, at: ns.range(of: "link]").location, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)
        let trailingFont = storage.attribute(.font, at: ns.range(of: "][ref]").location, effectiveRange: nil) as? NSFont
        XCTAssertLessThanOrEqual(trailingFont?.pointSize ?? 99, 0.2, "Reference syntax is folded")
    }

    func testActiveLineRevealsInlineSyntax() {
        let text = "Keep **bold\nwords** apart.\n\n# End"
        let storage = style(text, cursor: 2)
        let ns = text as NSString
        let markerColor = storage.attribute(.font, at: ns.range(of: "**bold").location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(markerColor?.pointSize ?? 0, 1, "Source markers stay visible while the paragraph is being edited")
    }

    func testReflowParagraphRangeAndReplacement() {
        let text = "Intro\n\none two three four five six\nseven\n\nOutro"
        guard let edit = MarkdownSourceReflow.reflowParagraph(in: text, line: 4, width: 15) else {
            return XCTFail("Expected a paragraph edit")
        }
        XCTAssertEqual(edit.lines, 3...4)
        XCTAssertEqual((text as NSString).substring(with: edit.range), "one two three four five six\nseven")
        XCTAssertEqual(edit.replacement, "one two three\nfour five six\nseven")
        XCTAssertNil(MarkdownSourceReflow.reflowParagraph(in: text, line: 2, width: 15))
    }

    func testLineNumberAndLocationMapping() {
        let ns = "a\nbb\nccc" as NSString
        XCTAssertEqual(MarkdownSourceReflow.lineNumber(at: 0, in: ns), 1)
        XCTAssertEqual(MarkdownSourceReflow.lineNumber(at: 2, in: ns), 2)
        XCTAssertEqual(MarkdownSourceReflow.lineNumber(at: 8, in: ns), 3)
        XCTAssertEqual(MarkdownSourceReflow.sourceRange(of: 2...3, in: ns), NSRange(location: 2, length: 6))

        let old = "one two\nthree" as NSString
        let new = "one\ntwo three" as NSString
        let loc = old.range(of: "three").location + 2
        let mapped = MarkdownSourceReflow.mapLocation(loc, in: old, oldRange: NSRange(location: 0, length: old.length), to: new)
        XCTAssertEqual(mapped, new.range(of: "three").location + 2)
    }

    func testSourceLineWidthSettingPersists() {
        let defaults = isolatedDefaults()

        let vm = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(vm.sourceLineWidth, MarkdownSourceReflow.defaultWidth)
        vm.sourceLineWidth = 0
        XCTAssertEqual(makeIsolatedViewModel(defaults: defaults).sourceLineWidth, 0)
    }
}
