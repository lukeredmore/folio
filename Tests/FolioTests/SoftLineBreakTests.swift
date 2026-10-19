import AppKit
import XCTest
@testable import Folio

@MainActor
final class SoftLineBreakTests: XCTestCase {

    private let listSample = """
    # Stacks

    - SuperStarNetworkStack: a VPC with a NAT gateway, and a SuperStar service
      environment that depends on PCLS. SuperStar provisions the PrivateLink to PCLS and the
      `pcls.amazon.com` private zone.
    - CruxAnalyzerStack: the CRUX Analysis and Feedback SNS topics.

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
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "SuperStar service", in: listSample)))
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "PCLS and the", in: listSample)))
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "private zone.", in: listSample)),
                       "The newline that ends a list item is a block boundary")
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "# Stacks", in: listSample)))
    }

    func testHardLineBreakIsKept() {
        let storage = style(listSample, cursor: 0)
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "line one", in: listSample)))
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "line two  ", in: listSample)))
    }

    func testActiveParagraphKeepsSourceLineBreaks() {
        let cursor = (listSample as NSString).range(of: "environment").location
        let storage = style(listSample, cursor: cursor)
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "SuperStar service", in: listSample)))
        XCTAssertFalse(isSoftBreak(storage, at: newlineLocation(after: "PCLS and the", in: listSample)))
        XCTAssertTrue(isSoftBreak(storage, at: newlineLocation(after: "line one", in: listSample)),
                      "Other paragraphs stay joined")
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
        let suite = "com.folio.tests.sourcewidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let vm = EditorWorkspaceViewModel(userDefaults: defaults)
        XCTAssertEqual(vm.sourceLineWidth, MarkdownSourceReflow.defaultWidth)
        vm.sourceLineWidth = 0
        XCTAssertEqual(EditorWorkspaceViewModel(userDefaults: defaults).sourceLineWidth, 0)
    }
}
