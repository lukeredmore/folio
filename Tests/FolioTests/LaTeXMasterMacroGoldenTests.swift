import AppKit
import XCTest
@testable import Folio

/// Golden render of child files that get their macros from a master file.
///
/// Regenerate after an intended change:
/// `bazel test //:FolioTests --test_filter=LaTeXMasterMacroGoldenTests --test_env=UPDATE_GOLDENS="$PWD" --strategy=TestRunner=local`
/// from the repository root. `UPDATE_GOLDENS` is the checkout to write into, because tests read
/// the golden from their runfiles.
@MainActor
final class LaTeXMasterMacroGoldenTests: XCTestCase {
    private static let goldenPath = "Tests/FolioTests/Fixtures/latex_master/golden/render.txt"
    private static let goldenURL = LaTeXProjectFixtures.fixtureDirectory.appendingPathComponent("golden/render.txt")

    override func setUp() {
        super.setUp()
        LaTeXProjectContext.removeAll()
    }

    override func tearDown() {
        LaTeXProjectContext.removeAll()
        super.tearDown()
    }

    /// A temporary copy of the fixture project, so file stamps and caches start fresh.
    private func fixtureCopy() throws -> URL {
        let directory = try makeTemporaryDirectory("LaTeXMasterFixture")
        let items = try FileManager.default.contentsOfDirectory(at: LaTeXProjectFixtures.fixtureDirectory, includingPropertiesForKeys: nil)
        for item in items where item.lastPathComponent != "golden" {
            try FileManager.default.copyItem(at: item, to: directory.appendingPathComponent(item.lastPathComponent))
        }
        return directory
    }

    func testChildFilesRenderMatchesGolden() throws {
        let directory = try fixtureCopy()
        let cases: [(file: String, cursorLine: Int)] = [
            ("chapter.tex", 0),
            ("chapter.tex", 8),
            ("texroot-chapter.tex", 0),
            ("emacs-chapter.tex", 0)
        ]
        var actual = ""
        for (file, cursorLine) in cases {
            let (storage, analysis) = try LaTeXProjectFixtures.style(directory.appendingPathComponent(file), cursorLine: cursorLine)
            actual += "## \(file), cursor on line \(cursorLine + 1)\n"
            actual += LaTeXRenderDump.dump(storage, decorations: analysis.decorations)
        }

        if let checkout = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] {
            let target = URL(fileURLWithPath: checkout).appendingPathComponent(Self.goldenPath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: target, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        if actual != expected {
            let diffLine =
                zip(actual.components(separatedBy: "\n"), expected.components(separatedBy: "\n"))
                .first { $0 != $1 }
                .map { "actual:   \($0.0)\nexpected: \($0.1)" } ?? "lengths differ"
            XCTFail("Render differs from \(Self.goldenURL.path). First difference:\n\(diffLine)\nRegenerate with UPDATE_GOLDENS if intended.")
        }
    }
}
