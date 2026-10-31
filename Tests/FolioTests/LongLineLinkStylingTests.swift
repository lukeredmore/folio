import AppKit
import XCTest
@testable import Folio

/// Link styling on very long lines, such as minified JSON or a one-line backup file.
@MainActor
final class LongLineLinkStylingTests: XCTestCase {
    private func style(_ markdown: String) -> NSTextStorage {
        let storage = NSTextStorage(string: markdown)
        _ = MarkdownLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            typography: .default,
            sourceCodeMode: false,
            focusMode: false,
            selectedRange: NSRange(location: 0, length: 0),
            containerWidth: 720
        )
        return storage
    }

    private func bareLinkLine(links: Int) -> String {
        (0..<links).map { "\"https://example.com/script/\($0).js\"," }.joined(separator: " ")
    }

    func testBareLinksOnOneLineScaleLinearly() {
        // Each link used to rescan its whole line, so a line with many links styled in quadratic time.
        let largeLine = bareLinkLine(links: 400) as NSString
        XCTAssertLessThan(largeLine.length, MarkdownLiveStyler.maxStyledLineLength, "the large input must still be styled")
        XCTAssertEqual(
            style(largeLine as String).attribute(.underlineStyle, at: largeLine.range(of: "example.com/script/399").location, effectiveRange: nil)
                as? Int,
            NSUnderlineStyle.single.rawValue)
        assertNearLinearScaling("bare links on one line", small: 100) { links in
            _ = style(bareLinkLine(links: links))
        }
    }

    func testLineOverStyledLengthKeepsBaseAttributes() {
        let longLine = bareLinkLine(links: 1000)
        XCTAssertGreaterThan((longLine as NSString).length, MarkdownLiveStyler.maxStyledLineLength)
        let markdown = longLine + "\n\nSee https://example.com/next for **more**."
        let storage = style(markdown)
        var run = NSRange()
        _ = storage.attributes(at: 0, effectiveRange: &run)
        XCTAssertGreaterThanOrEqual(run.length, (longLine as NSString).length, "the long line must be one attribute run")
        let nextLink = (markdown as NSString).range(of: "example.com/next")
        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: nextLink.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue,
            "the line after the long line must still be styled")
    }

    func testOneLongLineStylesAndLaysOutLinearly() {
        // TextKit layout of one paragraph with many attribute runs grows faster than quadratically.
        assertNearLinearScaling("style and lay out one long line", small: 1500) { links in
            let storage = style(bareLinkLine(links: links))
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude))
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
        }
    }

    func testByteColumnsMatchStringIndexConversionAtEveryCharacterBoundary() {
        // Bridged from NSString, like the line text of a style pass.
        let line = ("a é 😀 日本 x\u{301} 👩‍👩‍👧 [b](c) end" as NSString).substring(from: 0)
        let utf8 = line.utf8
        var columns = MarkdownLiveStyler.LineUTF8Columns(line)
        var boundaries = line.unicodeScalars.indices.map { utf8.distance(from: utf8.startIndex, to: $0) }
        boundaries.append(utf8.count)
        // Forward lookups, then lookups that move back to an earlier column.
        for column in boundaries + boundaries.reversed() {
            let index = utf8.index(utf8.startIndex, offsetBy: column)
            XCTAssertEqual(
                columns.utf16Offset(ofByteColumn: column), NSRange(utf8.startIndex..<index, in: line).length, "byte column \(column)")
        }
        XCTAssertEqual(columns.utf16Offset(ofByteColumn: utf8.count + 10), (line as NSString).length)
        XCTAssertEqual(columns.utf16Offset(ofByteColumn: -3), 0)
    }
}
