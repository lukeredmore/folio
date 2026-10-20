import Foundation
import XCTest
@testable import Folio

final class GfmSpecParityTests: XCTestCase {

    func testUpstreamGFMSpecAndExtensionsFullParity() throws {
        let gfmSpecURL = try locateSpecFixture("third_party/markdown_spec/gfm_spec.json")
        let gfmExtURL = try locateSpecFixture("third_party/markdown_spec/gfm_extensions.json")

        let gfmSpecData = try Data(contentsOf: gfmSpecURL)
        let gfmExtData = try Data(contentsOf: gfmExtURL)

        let specEntries = try JSONDecoder().decode([UpstreamSpecTestEntry].self, from: gfmSpecData)
        let extEntries = try JSONDecoder().decode([UpstreamSpecTestEntry].self, from: gfmExtData)

        XCTAssertGreaterThanOrEqual(specEntries.count, 670, "Expected at least 670 upstream GFM spec examples")
        XCTAssertGreaterThanOrEqual(extEntries.count, 30, "Expected at least 30 upstream GFM extensions examples")

        var failures: [String] = []
        for entry in specEntries {
            let actual = MarkdownLiveStyler.renderHTML(entry.markdown, extensions: entry.extensions)
            if actual != entry.html {
                failures.append("gfm_spec.json Example \(entry.example) (\(entry.section)): expected \(entry.html.debugDescription), got \(actual.debugDescription)")
            }
        }
        let defaultExtSuite = ["table", "strikethrough", "autolink", "tagfilter", "footnotes", "tasklist"]
        for entry in extEntries {
            guard entry.html.trimmingCharacters(in: .whitespacesAndNewlines) != "<IGNORE>" else { continue }
            var exts = defaultExtSuite
            for ext in entry.extensions where !exts.contains(ext) {
                exts.append(ext)
            }
            let actual = MarkdownLiveStyler.renderHTML(entry.markdown, extensions: exts)
            if actual != entry.html {
                failures.append("gfm_extensions.json Example \(entry.example) (\(entry.section)): expected \(entry.html.debugDescription), got \(actual.debugDescription)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Failed \(failures.count) upstream GFM spec tests:\n\(failures.prefix(10).joined(separator: "\n"))"
        )
    }
}
