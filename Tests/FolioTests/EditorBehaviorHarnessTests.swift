import AppKit
import Foundation
import XCTest
@testable import Folio
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioTestSupport
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

/// Runs the shared behavior specifications (`tst/specs/editor_behaviors.json`) end-to-end through
/// the production `MainWindowView`, `EditorWorkspaceViewModel`, and `HybridMarkdownTextView`.
@MainActor
final class EditorBehaviorHarnessTests: XCTestCase {

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

    func testEditorHarnessMatchesSharedCursorEditSpecs() throws {
        let spec = try loadSpecDocument()
        XCTAssertGreaterThanOrEqual(spec.cursor_edit_cases.count, 15)

        let harness = try EditorHarness(lineCount: 12)
        defer { harness.tearDown() }

        for testCase in spec.cursor_edit_cases {
            let (inputText, inputCursorUTF16) = splitUTF16Cursor(testCase.input)
            let (expectedText, expectedCursorUTF16) = splitUTF16Cursor(testCase.expected)
            let expectedSelection = NSRange(location: expectedCursorUTF16, length: 0)

            switch testCase.action {
            case "newline":
                // In source code mode, every newline case (including plain paragraph soft breaks)
                // maps 1:1 to `tst/specs/editor_behaviors.json`.
                harness.viewModel.sourceCodeMode = true
                harness.drainUntilIdle()
                loadDocument(inputText, selection: NSRange(location: inputCursorUTF16, length: 0), into: harness)
                harness.textView.insertNewline(nil)
                harness.drainUntilIdle()
                assertHarnessState(
                    harness,
                    expectedText: expectedText,
                    expectedSelection: expectedSelection,
                    context: "\(testCase.id) (sourceCodeMode)"
                )

                // In live WYSIWYG mode, list, task, and blockquote continuations (and empty-item
                // clearing) take the exact same path on Return; plain-paragraph Return intentionally
                // inserts a paragraph break via `startNewParagraphIfSoftBreak()`.
                if testCase.id != "newline_plain_paragraph_splits_line" {
                    harness.viewModel.sourceCodeMode = false
                    harness.drainUntilIdle()
                    loadDocument(inputText, selection: NSRange(location: inputCursorUTF16, length: 0), into: harness)
                    harness.pressReturn()
                    assertHarnessState(
                        harness,
                        expectedText: expectedText,
                        expectedSelection: expectedSelection,
                        context: "\(testCase.id) (live mode Return)"
                    )
                }

            case "toggle_delimiter":
                harness.viewModel.sourceCodeMode = false
                harness.drainUntilIdle()
                loadDocument(inputText, selection: NSRange(location: inputCursorUTF16, length: 0), into: harness)
                let delim = testCase.delimiter ?? "**"
                harness.viewModel.applyInlineFormatting(prefix: delim, suffix: delim, placeholder: "text")
                harness.drainUntilIdle()
                assertHarnessState(
                    harness,
                    expectedText: expectedText,
                    expectedSelection: expectedSelection,
                    context: testCase.id
                )

            case "set_heading_level":
                harness.viewModel.sourceCodeMode = false
                harness.drainUntilIdle()
                loadDocument(inputText, selection: NSRange(location: inputCursorUTF16, length: 0), into: harness)
                harness.viewModel.setHeadingLevel(Int(testCase.level ?? 0))
                harness.drainUntilIdle()
                assertHarnessState(
                    harness,
                    expectedText: expectedText,
                    expectedSelection: expectedSelection,
                    context: testCase.id
                )

            case "toggle_task_checkbox":
                harness.viewModel.sourceCodeMode = false
                harness.drainUntilIdle()
                loadDocument(inputText, selection: NSRange(location: inputCursorUTF16, length: 0), into: harness)
                harness.viewModel.toggleTaskCheckboxAtSelection()
                harness.drainUntilIdle()
                assertHarnessState(
                    harness,
                    expectedText: expectedText,
                    expectedSelection: expectedSelection,
                    context: testCase.id
                )

            default:
                XCTFail("Unknown action \(testCase.action) in \(testCase.id)")
            }
        }
    }

    func testEditorHarnessMatchesSharedFoldRevealSpecs() throws {
        let spec = try loadSpecDocument()
        XCTAssertFalse(spec.fold_reveal_cases.isEmpty)

        let harness = try EditorHarness(lineCount: 12)
        defer { harness.tearDown() }
        harness.viewModel.sourceCodeMode = false
        harness.viewModel.focusMode = false
        harness.drainUntilIdle()

        for testCase in spec.fold_reveal_cases {
            let (inputText, utf16Cursor) = splitUTF16Cursor(testCase.input)
            let endLocation = (inputText as NSString).length

            // Load at the trailing line first, then move selection onto `utf16Cursor` so
            // `Coordinator.textViewDidChangeSelection` drives the real incremental restyle.
            loadDocument(inputText, selection: NSRange(location: endLocation, length: 0), into: harness)
            harness.textView.setSelectedRange(NSRange(location: utf16Cursor, length: 0))
            harness.drainUntilIdle()
            harness.waitUntilStyledAtCurrentWidth()

            let storage = try XCTUnwrap(harness.textView.textStorage)
            let revealedColor = harness.viewModel.theme.markdownTokenNSColor.withAlphaComponent(0.85)
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
                "Case \(testCase.id): active cursor line must not fold syntax, folded [\(describe(folded))]"
            )
            XCTAssertNil(
                RestyleEquivalenceOracle.firstMismatch(in: harness),
                "Case \(testCase.id): incremental restyle diverged from full restyle"
            )
        }
    }

    func testEditorHarnessSelectionWrappingUnicodeCheckboxClickAndUndoRedo() throws {
        let harness = try EditorHarness(lineCount: 12)
        defer { harness.tearDown() }
        harness.viewModel.sourceCodeMode = false
        harness.drainUntilIdle()

        // 1. Non-empty selection wrapping and unwrapping preserves the inner selection.
        loadDocument("Hello world today", selection: NSRange(location: 6, length: 5), into: harness)
        harness.viewModel.applyInlineFormatting(prefix: "**", suffix: "**", placeholder: "bold")
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "Hello **world** today",
            expectedSelection: NSRange(location: 8, length: 5),
            context: "wrap selection with **"
        )

        harness.viewModel.applyInlineFormatting(prefix: "**", suffix: "**", placeholder: "bold")
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "Hello world today",
            expectedSelection: NSRange(location: 6, length: 5),
            context: "unwrap selection with **"
        )

        // 2. Multi-byte UTF-8 + astral surrogate-pair emoji selection edits, Undo/Redo, and
        // mouse-click checkbox toggling while selection stays on a different line.
        let unicodeInitial = "🦀 café\n- [ ] 🚀 launch"
        loadDocument(unicodeInitial, selection: NSRange(location: 3, length: 4), into: harness)

        harness.viewModel.applyInlineFormatting(prefix: "==", suffix: "==", placeholder: "highlight")
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "🦀 ==café==\n- [ ] 🚀 launch",
            expectedSelection: NSRange(location: 5, length: 4),
            context: "highlight UTF-16 selection after emoji"
        )

        harness.viewModel.setHeadingLevel(2)
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "## 🦀 ==café==\n- [ ] 🚀 launch",
            expectedSelection: NSRange(location: 8, length: 4),
            context: "promote unicode line to H2"
        )

        harness.viewModel.undo()
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "🦀 ==café==\n- [ ] 🚀 launch",
            expectedSelection: NSRange(location: 5, length: 4),
            context: "undo H2 promotion restores selection"
        )

        harness.viewModel.redo()
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "## 🦀 ==café==\n- [ ] 🚀 launch",
            expectedSelection: NSRange(location: 8, length: 4),
            context: "redo H2 promotion restores shifted selection"
        )

        // Clicking the checkbox on line 2 toggles `[ ]` <-> `[x]` without moving selection off line 1.
        let boxLocation = (harness.textView.string as NSString).range(of: "[ ]").location
        XCTAssertNotEqual(boxLocation, NSNotFound)
        harness.viewModel.toggleTaskCheckbox(at: boxLocation)
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "## 🦀 ==café==\n- [x] 🚀 launch",
            expectedSelection: NSRange(location: 8, length: 4),
            context: "click checkbox checks item while keeping selection on line 1"
        )

        // Asymmetric hyperlink formatting still wraps selection with `[...](https://)`.
        harness.viewModel.applyInlineFormatting(prefix: "[", suffix: "](https://)", placeholder: "link")
        harness.drainUntilIdle()
        assertHarnessState(
            harness,
            expectedText: "## 🦀 ==[café](https://)==\n- [x] 🚀 launch",
            expectedSelection: NSRange(location: 9, length: 4),
            context: "asymmetric hyperlink wrap"
        )
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
        throw NSError(domain: "EditorBehaviorHarnessTests", code: 1)
    }

    private func splitUTF16Cursor(_ annotated: String) -> (text: String, utf16Offset: Int) {
        let nsAnnotated = annotated as NSString
        let markerRange = nsAnnotated.range(of: Self.cursorMarker)
        guard markerRange.location != NSNotFound else {
            XCTFail("Missing cursor marker in \(annotated)")
            return (annotated, 0)
        }
        let clean = nsAnnotated.replacingCharacters(in: markerRange, with: "")
        return (clean, markerRange.location)
    }

    private func loadDocument(_ text: String, selection: NSRange, into harness: EditorHarness) {
        harness.viewModel.markdownText = text
        harness.viewModel.currentSelectedRange = selection
        harness.textView.applyProgrammaticDocumentText(text, selectedRange: selection)
        harness.drainUntilIdle()
    }

    private func assertHarnessState(
        _ harness: EditorHarness,
        expectedText: String,
        expectedSelection: NSRange,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(harness.textView.string, expectedText, "TextView text mismatch for \(context)", file: file, line: line)
        XCTAssertEqual(harness.textView.selectedRange(), expectedSelection, "TextView selection mismatch for \(context)", file: file, line: line)
        XCTAssertEqual(harness.viewModel.markdownText, expectedText, "ViewModel markdownText mismatch for \(context)", file: file, line: line)
        XCTAssertEqual(
            harness.viewModel.currentSelectedRange,
            expectedSelection,
            "ViewModel currentSelectedRange mismatch for \(context)",
            file: file,
            line: line
        )
        XCTAssertNil(
            RestyleEquivalenceOracle.firstMismatch(in: harness),
            "Incremental restyle mismatch after \(context)",
            file: file,
            line: line
        )
    }

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
