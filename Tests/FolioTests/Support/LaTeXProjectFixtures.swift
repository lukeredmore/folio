import AppKit
import XCTest
@testable import Folio

/// The `Fixtures/latex_master` project, a counting file system, and a renderer that dumps what a
/// styled LaTeX document shows.
enum LaTeXProjectFixtures {
    static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/latex_master", isDirectory: true)

    /// A file system that counts operations, so tests can assert on reads without timing.
    final class CountingFileSystem: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var stats = 0
        private(set) var reads: [String] = []
        private(set) var listings = 0

        var fileSystem: LaTeXProjectFileSystem {
            let live = LaTeXProjectFileSystem.live
            return LaTeXProjectFileSystem(
                stamp: { [self] url in
                    lock.withLock { stats += 1 }
                    return live.stamp(url)
                },
                readText: { [self] url in
                    lock.withLock { reads.append(url.lastPathComponent) }
                    return live.readText(url)
                },
                listDirectory: { [self] url in
                    lock.withLock { listings += 1 }
                    return live.listDirectory(url)
                }
            )
        }

        func reset() {
            lock.withLock {
                stats = 0
                reads = []
                listings = 0
            }
        }
    }

    /// Writes `files` (relative path to contents) under `directory`.
    static func write(_ files: [String: String], in directory: URL) throws {
        for (path, contents) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Styles `fileURL` as the editor does, with the cursor at the start of `cursorLine`.
    @MainActor
    static func style(
        _ fileURL: URL,
        cursorLine: Int,
        width: CGFloat = 900
    ) throws -> (storage: NSTextStorage, analysis: MarkdownDocumentAnalysis) {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let storage = NSTextStorage(string: text)
        let lines = text.components(separatedBy: "\n")
        let location = lines.prefix(cursorLine).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let analysis = LaTeXLiveStyler.applyStyles(
            to: storage,
            theme: .daylight,
            sourceCodeMode: false,
            prettyMode: true,
            focusMode: false,
            selectedRange: NSRange(location: min(location, storage.length), length: 0),
            containerWidth: width,
            baseDirectoryURL: fileURL.deletingLastPathComponent(),
            fileURL: fileURL
        )
        return (storage, analysis)
    }
}
