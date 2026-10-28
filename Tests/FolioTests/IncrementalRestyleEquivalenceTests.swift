import AppKit
import XCTest
@testable import Folio

/// Property tests for the live restyle: seeded pseudo-random edits go through the real key path,
/// and after every operation the editor must match a full restyle of the same text
/// (`RestyleEquivalenceOracle`). The seeds are fixed, so a failure reproduces with the reported
/// seed and operation index.
@MainActor
final class IncrementalRestyleEquivalenceTests: XCTestCase {
    private static let operationsPerFixture = 300

    func testRichMediaShowcaseEditsMatchFullRestyle() throws {
        try runEdits(
            "rich_media_showcase",
            workspace: PerfFixtures.makeWorkspace(copyingExample: "rich_media_showcase.md"),
            seed: 0x5EED_0001
        )
    }

    func testLaTeXMathShowcaseEditsMatchFullRestyle() throws {
        try runEdits(
            "latex_math_showcase",
            workspace: PerfFixtures.makeWorkspace(copyingExample: "latex_math_showcase.md"),
            seed: 0x5EED_0002
        )
    }

    func testHTMLBlocksShowcaseEditsMatchFullRestyle() throws {
        try runEdits(
            "html_blocks_showcase",
            workspace: PerfFixtures.makeWorkspace(copyingExample: "html_blocks_showcase.md"),
            seed: 0x5EED_0004
        )
    }

    func testPerfFixtureEditsMatchFullRestyle() throws {
        try runEdits("perf_200", workspace: PerfFixtures.makeWorkspace(lineCount: 200), seed: 0x5EED_0003)
    }

    /// The LaTeX styler reuses cached blocks. Multi-line macro calls, layout lines, and font
    /// switches make a block depend on text before and after it, so edits that open or close a
    /// call on another line must restyle it.
    func testLaTeXMultiLineCallEditsMatchFullRestyle() throws {
        LaTeXProjectContext.removeAll()
        defer { LaTeXProjectContext.removeAll() }
        let directory = try makeTemporaryDirectory("LaTeXEquivalence").appendingPathComponent("project")
        try FileManager.default.copyItem(at: LaTeXProjectFixtures.fixtureDirectory, to: directory)
        let fileURL = directory.appendingPathComponent("chapter.tex")
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let workspace = PerfFixtures.Workspace(directory: directory, fileURL: fileURL, document: PerfFixtures.Document(markdown: text, paragraphLines: []))
        let delta = try runEdits("latex_master_chapter", workspace: workspace, seed: 0x5EED_0004, syntax: EditOperationGenerator.latexSyntax)
        XCTAssertGreaterThan(delta?.latexBlocksReusedCount ?? 0, 0, "the edits must exercise reuse of cached blocks")
    }

    /// Runs the edits and returns the counters for them, or nil when a check failed.
    @discardableResult
    private func runEdits(
        _ name: String,
        workspace: PerfFixtures.Workspace,
        seed: UInt64,
        syntax: [String] = EditOperationGenerator.markdownSyntax
    ) throws -> EditorPerfCounters? {
        let harness = try EditorHarness(workspace: workspace)
        defer { harness.tearDown() }
        settleBackgroundRenders(harness)
        if let mismatch = RestyleEquivalenceOracle.firstMismatch(in: harness) {
            XCTFail("\(name): the initial restyle differs from a full restyle: \(mismatch)")
            return nil
        }

        var generator = EditOperationGenerator(seed: seed, blockSyntax: syntax)
        var history: [EditOperation] = []
        var fullRestyleReasons: [String: Int] = [:]
        let before = harness.counters
        for index in 0..<Self.operationsPerFixture {
            let operation = generator.next(in: harness)
            history.append(operation)
            let fullBefore = harness.counters.fullRangeRestyleCount
            operation.perform(on: harness)
            settleBackgroundRenders(harness)
            if harness.counters.fullRangeRestyleCount > fullBefore {
                let reason = harness.coordinator.lastFullRestyleReason?.rawValue ?? "incremental"
                fullRestyleReasons[reason, default: 0] += 1
            }
            if let mismatch = RestyleEquivalenceOracle.firstMismatch(in: harness) {
                let recent = history.suffix(6).map(\.description).joined(separator: ", ")
                XCTFail(
                    """
                    \(name): seed \(String(seed, radix: 16)), operation \(index) (\(operation)) left the \
                    editor different from a full restyle: \(mismatch). Last operations: \(recent)
                    """)
                return nil
            }
        }
        let delta = harness.counters.delta(since: before)
        PerfReport.record(
            "incrementalEquivalence_\(name)",
            [
                "operations": Self.operationsPerFixture,
                "seed": String(seed, radix: 16),
                "restyleCount": delta.restyleCount,
                "fullRangeRestyleCount": delta.fullRangeRestyleCount,
                "charactersRestyled": delta.charactersRestyled,
                "operationsWithFullRestyleByLastReason": fullRestyleReasons,
                "latexBlocksReusedCount": delta.latexBlocksReusedCount
            ])
        return delta
    }

    /// Diagram renders finish in the background and trigger a restyle. Waiting for them keeps
    /// the editor and the reference restyle on the same render cache state.
    private func settleBackgroundRenders(_ harness: EditorHarness) {
        harness.waitUntil(timeout: 10) { DiagramImageRenderer.shared.waitUntilIdle(timeout: 0.001) }
        harness.waitUntil(timeout: 20) { !harness.textView.hasPendingHTMLBlockLayout }
        harness.waitUntilStyledAtCurrentWidth()
    }
}

/// One user action in the property test.
enum EditOperation: CustomStringConvertible {
    case type(String)
    case returnKey
    case backspace
    case moveCursor(line: Int, column: Int)

    var description: String {
        switch self {
        case .type(let text): return "type \(text.debugDescription)"
        case .returnKey: return "Return"
        case .backspace: return "Backspace"
        case let .moveCursor(line, column): return "move to line \(line) column \(column)"
        }
    }

    @MainActor
    func perform(on harness: EditorHarness) {
        switch self {
        case .type(let text): harness.type(text)
        case .returnKey: harness.pressReturn()
        case .backspace: harness.pressBackspace()
        case let .moveCursor(line, column): harness.moveCursor(toLine: line, column: column)
        }
    }
}

/// Seeded generator of `EditOperation`s. Block syntax is typed at the start of a line half of
/// the time, so it changes block structure as well as inline text. Reference links,
/// reference definitions, and 4-space indents change how cmark parses lines outside the
/// edited block.
struct EditOperationGenerator {
    private var random: SplitMix64
    private var pending: [EditOperation] = []
    private static let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789 ")
    static let markdownSyntax = ["```", "$$", "|", "- ", "# ", "[ ] ", "[k]", "[k]: /k", "    "]
    /// Opens and closes macro calls on other lines, and adds layout lines and font switches.
    static let latexSyntax = [
        "\\ENTRY{", "}", "{", "\\\\", "%", "\\Kw{", "\\itshape ", "\\begin{center}", "\\end{center}", "\\Stack{", "\\vfill", "$"
    ]
    private let blockSyntax: [String]

    init(seed: UInt64, blockSyntax: [String] = Self.markdownSyntax) {
        random = SplitMix64(seed: seed)
        self.blockSyntax = blockSyntax
    }

    @MainActor
    mutating func next(in harness: EditorHarness) -> EditOperation {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        let roll = Int.random(in: 0..<100, using: &random)
        switch roll {
        case 0..<30:
            return .type(String(Self.letters.randomElement(using: &random) ?? "a"))
        case 30..<40:
            return .returnKey
        case 40..<54:
            return .backspace
        case 54..<84:
            let syntax = blockSyntax.randomElement(using: &random) ?? "- "
            guard Bool.random(using: &random) else { return .type(syntax) }
            pending.append(.type(syntax))
            return .moveCursor(line: currentLine(in: harness), column: 0)
        default:
            let line = Int.random(in: 0..<max(1, harness.lineCount), using: &random)
            return .moveCursor(line: line, column: Int.random(in: 0..<40, using: &random))
        }
    }

    @MainActor
    private func currentLine(in harness: EditorHarness) -> Int {
        let location = harness.textView.selectedRange().location
        let prefix = (harness.text as NSString).substring(to: min(location, (harness.text as NSString).length))
        return prefix.components(separatedBy: "\n").count - 1
    }
}

/// Small deterministic random number generator, so seeds reproduce on every machine.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
