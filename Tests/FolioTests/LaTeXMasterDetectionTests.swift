import XCTest
@testable import Folio

/// Master-file rules, their bounds, and the project cache.
final class LaTeXMasterDetectionTests: XCTestCase {
    private let counter = LaTeXProjectFixtures.CountingFileSystem()

    override func setUp() {
        super.setUp()
        LaTeXProjectContext.removeAll()
    }

    override func tearDown() {
        LaTeXProjectContext.removeAll()
        super.tearDown()
    }

    /// Writes `files` into `<temp>/project`, so the parent-directory search only sees `project`.
    private func project(_ files: [String: String]) throws -> URL {
        let directory = try makeTemporaryDirectory("LaTeXMaster").resolvingSymlinksInPath().appendingPathComponent("project")
        try LaTeXProjectFixtures.write(files, in: directory)
        return directory
    }

    private func signature(of url: URL) throws -> LaTeXProjectSignature {
        let text = try String(contentsOf: url, encoding: .utf8)
        return LaTeXDocumentIndexer.buildIndex(string: text, nsString: text as NSString).projectSignature
    }

    private func resolveMaster(_ child: URL, limits: LaTeXProjectLimits = LaTeXProjectLimits()) throws -> LaTeXMasterResolution? {
        var resolver = LaTeXProjectResolver(fileSystem: counter.fileSystem, limits: limits, cache: LaTeXFileFactsCache())
        return resolver.resolveMaster(for: child, signature: try signature(of: child))
    }

    private let includingMaster = "\\documentclass{article}\n\\begin{document}\n\\input{child}\n\\end{document}\n"

    func testTexRootCommentWinsOverOtherRules() throws {
        let dir = try project([
            "child.tex": "% !TEX root = book/m.tex\n%%% TeX-master: \"other\"\nText.\n",
            "book/m.tex": "\\documentclass{book}\n",
            "other.tex": "\\documentclass{book}\n",
            "main.tex": includingMaster
        ])
        let master = try XCTUnwrap(try resolveMaster(dir.appendingPathComponent("child.tex")))
        XCTAssertEqual(master.url.lastPathComponent, "m.tex")
        XCTAssertEqual(master.rule, .texRoot)
    }

    func testTeXMasterVariable() throws {
        let dir = try project([
            "named.tex": "Text.\n%%% Local Variables:\n%%% TeX-master: \"book\"\n%%% End:\n",
            "self.tex": "Text.\n%%% TeX-master: t\n",
            "book.tex": "\\documentclass{book}\n\\input{self}\n"
        ])
        let named = try XCTUnwrap(try resolveMaster(dir.appendingPathComponent("named.tex")))
        XCTAssertEqual(named.url.lastPathComponent, "book.tex")
        XCTAssertEqual(named.rule, .texMaster)
        XCTAssertNil(try resolveMaster(dir.appendingPathComponent("self.tex")), "TeX-master: t means the file is its own master")
    }

    func testSiblingThenParentDocumentThatInputsTheFile() throws {
        let dir = try project([
            "ch/child.tex": "Text.\n",
            "ch/notes.tex": "\\input{child}\n",
            "book.tex": "\\documentclass{book}\n\\begin{document}\n\\include{ch/child.tex}\n\\end{document}\n",
            "ch/other.tex": "Text.\n"
        ])
        let parent = try XCTUnwrap(try resolveMaster(dir.appendingPathComponent("ch/child.tex")))
        XCTAssertEqual(parent.url.lastPathComponent, "book.tex", "a file without \\documentclass is not a master")
        XCTAssertEqual(parent.rule, .parentDocument)

        try LaTeXProjectFixtures.write(["ch/main.tex": includingMaster], in: dir)
        let sibling = try XCTUnwrap(try resolveMaster(dir.appendingPathComponent("ch/child.tex")))
        XCTAssertEqual(sibling.url.lastPathComponent, "main.tex", "the same directory is searched before the parent")
        XCTAssertEqual(sibling.rule, .siblingDocument)
    }

    func testFileWithDocumentClassIsItsOwnMaster() throws {
        let dir = try project(["child.tex": "\\documentclass{article}\nText.\n", "main.tex": includingMaster])
        XCTAssertNil(try resolveMaster(dir.appendingPathComponent("child.tex")))
    }

    func testCyclesAndChainsTerminate() throws {
        let dir = try project([
            "a.tex": "% !TEX root = b.tex\n",
            "b.tex": "% !TEX root = a.tex\n\\documentclass{article}\n",
            "self.tex": "% !TEX root = self.tex\n",
            "c1.tex": "% !TEX root = c2.tex\n",
            "c2.tex": "%%% TeX-master: \"c3\"\n",
            "c3.tex": "\\documentclass{article}\n%%% TeX-master: t\n"
        ])
        XCTAssertEqual(try resolveMaster(dir.appendingPathComponent("a.tex"))?.url.lastPathComponent, "b.tex")
        XCTAssertNil(try resolveMaster(dir.appendingPathComponent("self.tex")))
        let chain = try XCTUnwrap(try resolveMaster(dir.appendingPathComponent("c1.tex")))
        XCTAssertEqual(chain.url.lastPathComponent, "c3.tex")
        XCTAssertEqual(chain.rule, .texRoot, "the rule is the one that found the first link")
        var limits = LaTeXProjectLimits()
        limits.maxMasterHops = 1
        XCTAssertEqual(try resolveMaster(dir.appendingPathComponent("c1.tex"), limits: limits)?.url.lastPathComponent, "c2.tex")
    }

    func testSearchStopsAtFileReadAndDirectoryCaps() throws {
        var files = ["child.tex": "Text.\n", "z-main.tex": includingMaster]
        for n in 0..<10 { files["a\(n).tex"] = "Text \(n).\n" }
        let dir = try project(files)
        let child = dir.appendingPathComponent("child.tex")
        XCTAssertEqual(try resolveMaster(child)?.url.lastPathComponent, "z-main.tex")

        var readCap = LaTeXProjectLimits()
        readCap.maxFilesRead = 5
        counter.reset()
        XCTAssertNil(try resolveMaster(child, limits: readCap))
        XCTAssertEqual(counter.reads.count, 5, "the search reads no more than maxFilesRead files")

        var entryCap = LaTeXProjectLimits()
        entryCap.maxDirectoryEntries = 4
        XCTAssertNil(try resolveMaster(child, limits: entryCap))
    }

    func testOversizedFilesAreSkipped() throws {
        let padding = String(repeating: "% padding line\n", count: 20)
        let dir = try project(["child.tex": "Text.\n", "main.tex": includingMaster + padding])
        var limits = LaTeXProjectLimits()
        limits.maxTeXFileBytes = 120
        XCTAssertNil(try resolveMaster(dir.appendingPathComponent("child.tex"), limits: limits))
        XCTAssertFalse(counter.reads.contains("main.tex"), "an oversized file is not read")
    }

    func testInheritedMacrosFollowInputsToTheDepthCap() throws {
        var files = [
            "child.tex": "Text.\n",
            "main.tex":
                "\\documentclass{article}\n\\newcommand{\\Top}{t}\n\\input{m1}\n\\begin{document}\n\\input{child}\n\\newcommand{\\Body}{b}\n\\end{document}\n"
        ]
        for n in 1...8 {
            files["m\(n).tex"] = "\\newcommand{\\M\(n)}{\(n)}\n\\input{m\(n + 1)}\n"
        }
        let dir = try project(files)
        let child = dir.appendingPathComponent("child.tex")
        var resolver = LaTeXProjectResolver(fileSystem: counter.fileSystem, limits: LaTeXProjectLimits(), cache: LaTeXFileFactsCache())
        let master = try XCTUnwrap(resolver.resolveMaster(for: child, signature: try signature(of: child)))
        let macros = resolver.inheritedMacros(from: master.url, excluding: child)
        XCTAssertNotNil(macros["\\Top"])
        XCTAssertNil(macros["\\Body"], "only the master's preamble counts")
        XCTAssertNotNil(macros["\\M6"])
        XCTAssertNil(macros["\\M7"], "inputs deeper than maxIncludeDepth are not followed")
    }

    func testSnapshotCacheIsInvalidatedByModificationDate() throws {
        let dir = try project([
            "child.tex": "Text.\n",
            "macros.tex": "\\newcommand{\\Old}{o}\n",
            "main.tex": "\\documentclass{article}\n\\input{macros}\n\\begin{document}\n\\input{child}\n\\end{document}\n"
        ])
        let child = dir.appendingPathComponent("child.tex")
        let key = LaTeXProjectContext.Key(fileURL: child, baseDirectoryURL: dir)
        let sig = try signature(of: child)
        let first = LaTeXProjectContext.refresh(key, signature: sig, fileSystem: counter.fileSystem)
        XCTAssertNotNil(first.inheritedMacros["\\Old"])
        XCTAssertTrue(counter.reads.contains("macros.tex"))

        counter.reset()
        let second = LaTeXProjectContext.refresh(key, signature: sig, fileSystem: counter.fileSystem)
        XCTAssertEqual(counter.reads, [], "unchanged files are not read again")
        XCTAssertEqual(second.version, first.version, "unchanged content keeps the version")

        let macrosURL = dir.appendingPathComponent("macros.tex")
        try "\\newcommand{\\New}{n}\n".write(to: macrosURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: macrosURL.path)
        counter.reset()
        let third = LaTeXProjectContext.refresh(key, signature: sig, fileSystem: counter.fileSystem)
        XCTAssertEqual(counter.reads, ["macros.tex"], "only the changed file is read")
        XCTAssertNotNil(third.inheritedMacros["\\New"])
        XCTAssertNil(third.inheritedMacros["\\Old"])
        XCTAssertNotEqual(third.version, first.version)
    }

    func testStylingReadsProjectOnlyOnFirstPass() throws {
        let dir = try project([
            "child.tex": "Text with \\Name{} here.\n",
            "main.tex": "\\documentclass{article}\n\\newcommand{\\Name}{N}\n\\begin{document}\n\\input{child}\n\\end{document}\n"
        ])
        let child = dir.appendingPathComponent("child.tex")
        let recorder = EditorPerfRecorder()
        func style(_ text: String) -> [String: LaTeXMacroDefinition] {
            EditorPerfScope.bind(recorder) {
                LaTeXDocumentIndexer.cachedIndexAndMacros(
                    string: text, nsString: text as NSString, baseDirectoryURL: dir, fileURL: child, sourceCodeMode: false
                ).macros
            }
        }
        let firstMacros = style("Text with \\Name{} here.\n")
        let afterOpen = recorder.counters.latexFileOperationCount
        XCTAssertNotNil(firstMacros["\\Name"])
        XCTAssertGreaterThan(afterOpen, 0, "the first styling resolves the project")
        for n in 0..<20 {
            _ = style("Text with \\Name{} here \(n).\n")
        }
        _ = style("\\input{newfile}\nText.\n")
        XCTAssertEqual(recorder.counters.latexFileOperationCount, afterOpen, "later styling passes do no file I/O")
    }
}
