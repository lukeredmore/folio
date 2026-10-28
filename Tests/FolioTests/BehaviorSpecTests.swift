import AppKit
import Foundation
import FolioEngineFFI
import XCTest
@testable import Folio

final class BehaviorSpecTests: XCTestCase {

    private static let cursorMarker = "ˇ"

    private struct SpecDocument: Decodable {
        let cursor_edit_cases: [CursorEditCase]
        let fold_reveal_cases: [FoldRevealCase]
    }

    private struct CursorEditCase: Decodable {
        let id: String
        let action: String
        let delimiter: String?
        let level: UInt8?
        let input: String
        let expected: String
    }

    private struct FoldRevealCase: Decodable {
        let id: String
        let input: String
        let expected_revealed_count: Int
        let expected_folded_min: Int
    }

    private func loadSpecDocument() throws -> SpecDocument {
        let candidates = [
            "tst/specs/editor_behaviors.json",
            "../../tst/specs/editor_behaviors.json"
        ]
        for rel in candidates {
            let url = URL(fileURLWithPath: rel)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(SpecDocument.self, from: data)
            }
        }
        XCTFail("Could not locate tst/specs/editor_behaviors.json")
        throw NSError(domain: "BehaviorSpecTests", code: 1)
    }

    private func splitCursor(_ annotated: String) -> (text: String, cursorByte: Int) {
        let utf8 = Array(annotated.utf8)
        let markerBytes = Array(Self.cursorMarker.utf8)
        guard let pos = findSubslice(in: utf8, needle: markerBytes) else {
            XCTFail("Missing cursor marker in \(annotated)")
            return (annotated, 0)
        }
        var cleanBytes = Array(utf8[..<pos])
        cleanBytes.append(contentsOf: utf8[(pos + markerBytes.count)...])
        let clean = String(decoding: cleanBytes, as: UTF8.self)
        return (clean, pos)
    }

    private func joinCursor(text: String, cursorByte: Int) -> String {
        let utf8 = Array(text.utf8)
        let clamped = max(0, min(cursorByte, utf8.count))
        var outBytes = Array(utf8[..<clamped])
        outBytes.append(contentsOf: Self.cursorMarker.utf8)
        outBytes.append(contentsOf: utf8[clamped...])
        return String(decoding: outBytes, as: UTF8.self)
    }

    private func findSubslice(in haystack: [UInt8], needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                return i
            }
        }
        return nil
    }

    func testStandaloneMatchesSharedCursorEditSpecs() throws {
        let spec = try loadSpecDocument()
        XCTAssertGreaterThanOrEqual(spec.cursor_edit_cases.count, 15)

        for testCase in spec.cursor_edit_cases {
            let (inputText, cursorByte) = splitCursor(testCase.input)
            let result: OTCursorEditResult = inputText.withCString { mdPtr in
                switch testCase.action {
                case "newline":
                    return ot_engine_apply_newline_at_cursor(mdPtr, cursorByte)
                case "toggle_delimiter":
                    let delim = testCase.delimiter ?? "**"
                    return delim.withCString { delimPtr in
                        ot_engine_toggle_symmetric_delimiter(mdPtr, cursorByte, delimPtr)
                    }
                case "set_heading_level":
                    return ot_engine_set_heading_level_at_cursor(mdPtr, cursorByte, testCase.level ?? 0)
                case "toggle_task_checkbox":
                    return ot_engine_toggle_task_checkbox_at_cursor(mdPtr, cursorByte)
                default:
                    XCTFail("Unknown action \(testCase.action) in \(testCase.id)")
                    return OTCursorEditResult(text: nil, cursor_byte: 0)
                }
            }
            defer { ot_engine_free_cursor_edit(result) }

            let actualText = result.text.map { String(cString: $0) } ?? ""
            let actualAnnotated = joinCursor(text: actualText, cursorByte: result.cursor_byte)
            XCTAssertEqual(
                actualAnnotated,
                testCase.expected,
                "Standalone behavior spec mismatch for case '\(testCase.id)'"
            )
        }
    }

    func testStandaloneLiveStylerMatchesSharedFoldRevealSpecs() throws {
        let spec = try loadSpecDocument()
        XCTAssertFalse(spec.fold_reveal_cases.isEmpty, "The spec must define fold_reveal_cases")

        for testCase in spec.fold_reveal_cases {
            let (inputText, cursorByte) = splitCursor(testCase.input)
            let prefixText = String(decoding: Array(inputText.utf8.prefix(cursorByte)), as: UTF8.self)
            let utf16Cursor = (prefixText as NSString).length
            let theme = EditorTheme.daylight

            let storage = NSTextStorage(string: inputText)
            _ = MarkdownLiveStyler.applyStyles(
                to: storage,
                theme: theme,
                sourceCodeMode: false,
                focusMode: false,
                selectedRange: NSRange(location: utf16Cursor, length: 0)
            )

            let revealedColor = theme.markdownTokenNSColor.withAlphaComponent(0.85)
            let folded = syntaxTokenRuns(in: storage) { attributes in
                attributes[MarkdownLiveStyler.collapsedTokenAttributeKey] != nil
            }
            let revealed = syntaxTokenRuns(in: storage) { attributes in
                attributes[MarkdownLiveStyler.collapsedTokenAttributeKey] == nil
                    && attributes[.foregroundColor] as? NSColor == revealedColor
            }
            let describe = { (runs: [NSRange]) in
                runs.map { (inputText as NSString).substring(with: $0).debugDescription }.joined(separator: ", ")
            }
            XCTAssertEqual(
                revealed.count,
                testCase.expected_revealed_count,
                "Case \(testCase.id): revealed syntax tokens were [\(describe(revealed))]"
            )
            XCTAssertGreaterThanOrEqual(
                folded.count,
                testCase.expected_folded_min,
                "Case \(testCase.id): folded syntax tokens were [\(describe(folded))]"
            )
            let activeLine = (inputText as NSString).lineRange(for: NSRange(location: utf16Cursor, length: 0))
            XCTAssertTrue(
                folded.allSatisfy { NSIntersectionRange($0, activeLine).length == 0 },
                "Case \(testCase.id): the cursor line must not fold syntax, folded [\(describe(folded))]"
            )
        }
    }

    /// Maximal runs of characters whose attributes satisfy `matches`.
    private func syntaxTokenRuns(
        in storage: NSTextStorage,
        where matches: ([NSAttributedString.Key: Any]) -> Bool
    ) -> [NSRange] {
        var runs: [NSRange] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            guard matches(attributes) else { return }
            if let last = runs.last, NSMaxRange(last) == range.location {
                runs[runs.count - 1] = NSUnionRange(last, range)
            } else {
                runs.append(range)
            }
        }
        return runs
    }
}
