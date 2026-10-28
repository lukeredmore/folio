import Foundation

/// Deterministic Markdown documents for the editor perf tests. The same `lineCount` always gives
/// the same text, so work counts and size ratios are comparable between runs and machines.
enum PerfFixtures {
    struct Document {
        let markdown: String
        /// Zero-based line numbers of plain paragraph lines, which are safe places to type.
        let paragraphLines: [Int]
        var lineCount: Int { markdown.components(separatedBy: "\n").count }
    }

    struct Workspace {
        let directory: URL
        let fileURL: URL
        let document: Document

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static let imageRelativePath = "assets/diagram.svg"

    /// Exactly `lineCount` lines. Sections mix headings, paragraphs, bullet and task lists, a
    /// Swift fence, a GFM table, inline and display math, and a local SVG image. Plain
    /// paragraph lines fill the remainder.
    static func document(lineCount: Int) -> Document {
        var lines: [String] = []
        var paragraphLines: [Int] = []
        var section = 1
        while lines.count + sectionLineCount <= lineCount {
            let start = lines.count
            let block = sectionLines(section)
            paragraphLines.append(start + 2)
            paragraphLines.append(start + 3)
            lines.append(contentsOf: block)
            section += 1
        }
        var filler = 1
        while lines.count < lineCount {
            paragraphLines.append(lines.count)
            lines.append("Filler paragraph line \(filler) keeps the document at its exact size.")
            filler += 1
        }
        return Document(markdown: lines.joined(separator: "\n"), paragraphLines: paragraphLines)
    }

    /// Writes `document(lineCount:)` and its SVG image into a new temporary directory.
    static func makeWorkspace(lineCount: Int) throws -> Workspace {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("FolioPerf-\(UUID().uuidString)", isDirectory: true)
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try svg.write(to: directory.appendingPathComponent(imageRelativePath), atomically: true, encoding: .utf8)
        let document = document(lineCount: lineCount)
        let fileURL = directory.appendingPathComponent("perf_\(lineCount).md")
        try document.markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return Workspace(directory: directory, fileURL: fileURL, document: document)
    }

    /// Copies `examples/<name>` and `examples/assets` into a new temporary directory, so edits
    /// never touch the checked-in example.
    static func makeWorkspace(copyingExample name: String) throws -> Workspace {
        let fm = FileManager.default
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples", isDirectory: true)
        let directory = fm.temporaryDirectory
            .appendingPathComponent("FolioExample-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: examples.appendingPathComponent("assets"), to: directory.appendingPathComponent("assets"))
        let fileURL = directory.appendingPathComponent(name)
        try fm.copyItem(at: examples.appendingPathComponent(name), to: fileURL)
        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        return Workspace(directory: directory, fileURL: fileURL, document: Document(markdown: markdown, paragraphLines: []))
    }

    private static let sectionLineCount = sectionLines(1).count

    private static func sectionLines(_ n: Int) -> [String] {
        [
            "## Section \(n)",
            "",
            "Paragraph \(n) has **bold**, *italic*, `code` and math $a_\(n)^2 + b^2 = c^2$ inline.",
            "It wraps onto a second source line that belongs to the same paragraph \(n).",
            "",
            "- Bullet \(n).1 links to [the guide](https://example.com/guide/\(n))",
            "- Bullet \(n).2 with ~~struck~~ text",
            "- [ ] Open task \(n)",
            "- [x] Done task \(n)",
            "",
            "```swift",
            "let value\(n) = \(n) * 2",
            "print(\"value: \\(value\(n))\")",
            "```",
            "",
            "| Name | Count | Note |",
            "| :--- | ---: | :---: |",
            "| row \(n) | \(n * 3) | ok |",
            "",
            "$$",
            "\\sum_{k=1}^{\(n)} k = \\frac{\(n)(\(n)+1)}{2}",
            "$$",
            "",
            "![Diagram \(n)](\(imageRelativePath))",
            ""
        ]
    }

    private static let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 80" width="320" height="80">
          <rect width="320" height="80" rx="10" fill="#1e293b"/>
          <text x="160" y="46" text-anchor="middle" fill="#f8fafc" font-size="16">perf fixture</text>
        </svg>
        """
}
