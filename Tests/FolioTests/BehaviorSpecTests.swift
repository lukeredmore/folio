import AppKit
import Foundation
import FolioEngineFFI
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels

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

    func testSpanEditUTF16MatchesSharedCursorEditSpecs() throws {
        let spec = try loadSpecDocument()
        XCTAssertGreaterThanOrEqual(spec.cursor_edit_cases.count, 15)

        for testCase in spec.cursor_edit_cases {
            let (inputText, cursorByte) = splitCursor(testCase.input)
            let utf16Cursor = utf16Offset(forUTF8ByteOffset: cursorByte, in: inputText)

            let edit: OTSpanEditResult = inputText.withCString { mdPtr in
                switch testCase.action {
                case "newline":
                    return ot_engine_edit_newline_utf16(mdPtr, utf16Cursor, 0)
                case "toggle_delimiter":
                    let delim = testCase.delimiter ?? "**"
                    return delim.withCString { delimPtr in
                        ot_engine_edit_symmetric_delimiter_utf16(mdPtr, utf16Cursor, 0, delimPtr)
                    }
                case "set_heading_level":
                    return ot_engine_edit_heading_level_utf16(mdPtr, utf16Cursor, 0, testCase.level ?? 0, false)
                case "toggle_task_checkbox":
                    return ot_engine_edit_task_checkbox_utf16(mdPtr, utf16Cursor, 0)
                default:
                    XCTFail("Unknown action \(testCase.action) in \(testCase.id)")
                    return OTSpanEditResult(replacement: nil, replace_loc: 0, replace_len: 0, select_loc: 0, select_len: 0)
                }
            }
            defer { ot_engine_free_span_edit(edit) }

            let replacement = edit.replacement.map { String(cString: $0) } ?? ""
            let replaceRange = NSRange(location: edit.replace_loc, length: edit.replace_len)
            let actualText = (inputText as NSString).replacingCharacters(in: replaceRange, with: replacement)
            XCTAssertEqual(edit.select_len, 0, "Expected collapsed cursor for case '\(testCase.id)'")
            let actualCursorByte = utf8ByteOffset(forUTF16Offset: edit.select_loc, in: actualText)
            let actualAnnotated = joinCursor(text: actualText, cursorByte: actualCursorByte)
            XCTAssertEqual(
                actualAnnotated,
                testCase.expected,
                "UTF-16 SpanEdit behavior spec mismatch for case '\(testCase.id)'"
            )
        }

        // Verify multi-byte UTF-8 ("café") and astral surrogate-pair emoji ("🦀", "🚀") UTF-16 span edits.
        let unicodeDoc = "🦀 café\n- [ ] 🚀 launch"
        let wrapCafe = applyUTF16SpanEdit(to: unicodeDoc) { mdPtr in
            "**".withCString { delimPtr in
                ot_engine_edit_symmetric_delimiter_utf16(mdPtr, 3, 4, delimPtr)
            }
        }
        XCTAssertEqual(wrapCafe.text, "🦀 **café**\n- [ ] 🚀 launch")
        XCTAssertEqual(wrapCafe.selection, NSRange(location: 5, length: 4))

        let unwrapCafe = applyUTF16SpanEdit(to: wrapCafe.text) { mdPtr in
            "**".withCString { delimPtr in
                ot_engine_edit_symmetric_delimiter_utf16(mdPtr, wrapCafe.selection.location, wrapCafe.selection.length, delimPtr)
            }
        }
        XCTAssertEqual(unwrapCafe.text, unicodeDoc)
        XCTAssertEqual(unwrapCafe.selection, NSRange(location: 3, length: 4))

        let promoteHeading = applyUTF16SpanEdit(to: unicodeDoc) { mdPtr in
            ot_engine_edit_heading_level_utf16(mdPtr, 3, 4, 2, false)
        }
        XCTAssertEqual(promoteHeading.text, "## 🦀 café\n- [ ] 🚀 launch")
        XCTAssertEqual(promoteHeading.selection, NSRange(location: 6, length: 4))

        // Second line starts at UTF-16 offset 8 ("🦀 café\n" = 2 + 1 + 4 + 1); cursor after "🚀 " is 8 + 6 + 2 + 1 = 17.
        let checkEmojiTask = applyUTF16SpanEdit(to: unicodeDoc) { mdPtr in
            ot_engine_edit_task_checkbox_utf16(mdPtr, 17, 6)
        }
        XCTAssertEqual(checkEmojiTask.text, "🦀 café\n- [x] 🚀 launch")
        XCTAssertEqual(checkEmojiTask.selection, NSRange(location: 17, length: 6))

        let continueEmojiTask = applyUTF16SpanEdit(to: checkEmojiTask.text) { mdPtr in
            ot_engine_edit_newline_utf16(mdPtr, (checkEmojiTask.text as NSString).length, 0)
        }
        XCTAssertEqual(continueEmojiTask.text, "🦀 café\n- [x] 🚀 launch\n- [ ] ")
        XCTAssertEqual(continueEmojiTask.selection, NSRange(location: (continueEmojiTask.text as NSString).length, length: 0))
    }

    private func utf16Offset(forUTF8ByteOffset byteOffset: Int, in text: String) -> Int {
        let clamped = max(0, min(byteOffset, text.utf8.count))
        let prefix = String(decoding: Array(text.utf8.prefix(clamped)), as: UTF8.self)
        return (prefix as NSString).length
    }

    private func utf8ByteOffset(forUTF16Offset utf16Offset: Int, in text: String) -> Int {
        let nsText = text as NSString
        let clamped = max(0, min(utf16Offset, nsText.length))
        return nsText.substring(to: clamped).utf8.count
    }

    private func applyUTF16SpanEdit(
        to text: String,
        build: (UnsafePointer<CChar>) -> OTSpanEditResult
    ) -> (text: String, selection: NSRange) {
        let edit = text.withCString { build($0) }
        defer { ot_engine_free_span_edit(edit) }
        let replacement = edit.replacement.map { String(cString: $0) } ?? ""
        let replaceRange = NSRange(location: edit.replace_loc, length: edit.replace_len)
        let updated = (text as NSString).replacingCharacters(in: replaceRange, with: replacement)
        return (updated, NSRange(location: edit.select_loc, length: edit.select_len))
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
