import XCTest
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

@MainActor
final class SidebarRootFilterTests: XCTestCase {

    private func makeFolder(files: [String: String]) throws -> URL {
        let folder = try makeTemporaryDirectory("FilterRoot")
        for (path, content) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    private func names(_ vm: EditorWorkspaceViewModel) -> Set<String> {
        Set(vm.flatMarkdownFiles.map(\.name))
    }

    func testFileTypeMapping() {
        XCTAssertEqual(SidebarFileType(fileExtension: "MD"), .markdown)
        XCTAssertEqual(SidebarFileType(fileExtension: "txt"), .plainText)
        XCTAssertEqual(SidebarFileType(fileExtension: "sty"), .latex)
        XCTAssertEqual(SidebarFileType(fileExtension: "bib"), .bibtex)
        XCTAssertNil(SidebarFileType(fileExtension: "png"))
        XCTAssertEqual(SidebarFileType.plainText.menuTitle, "Plain Text (.txt)")
        XCTAssertEqual(SidebarFileType.markdown.menuTitle, "Markdown (.markdown, .md, .mdown, .mkd)")

        let filter = SidebarRootFilter(hiddenFileTypes: [.plainText], excludedPaths: ["build-logs"])
        XCTAssertFalse(filter.showsFile(named: "notes.TXT"))
        XCTAssertTrue(filter.showsFile(named: "notes.md"))
        XCTAssertTrue(filter.excludes(relativePath: "build-logs"))
        XCTAssertTrue(filter.excludes(relativePath: "build-logs/2026"))
        XCTAssertFalse(filter.excludes(relativePath: "build-logs-old"))
        XCTAssertEqual(filter.shownExtensions(of: ["md", "txt", "tex"]), ["md", "tex"])
    }

    func testLocalFolderHidesFileTypesAndExcludedFoldersAndPersists() throws {
        let folder = try makeFolder(files: [
            "readme.md": "# Readme",
            "log.txt": "log",
            "paper/main.tex": "\\documentclass{article}",
            "paper/refs.bib": "@book{x}",
            "scratch/deep/idea.md": "# Idea"
        ])
        let defaults = isolatedDefaults()
        let vm = makeIsolatedViewModel(defaults: defaults)
        vm.loadWorkspaceFolder(folder)
        XCTAssertEqual(names(vm), ["readme.md", "log.txt", "main.tex", "refs.bib", "idea.md"])

        vm.setFileType(.plainText, shown: false, forRoot: folder)
        vm.setFileType(.bibtex, shown: false, forRoot: folder)
        XCTAssertEqual(names(vm), ["readme.md", "main.tex", "idea.md"])

        vm.excludeFolderFromSidebar(folder.appendingPathComponent("scratch", isDirectory: true))
        XCTAssertEqual(names(vm), ["readme.md", "main.tex"])
        let root = try XCTUnwrap(vm.rootFileNodes.first(where: \.isLocalRoot))
        XCTAssertFalse(root.children?.contains(where: { $0.name == "scratch" }) ?? true)
        XCTAssertEqual(
            vm.sidebarFilter(forRoot: folder),
            SidebarRootFilter(hiddenFileTypes: [.plainText, .bibtex], excludedPaths: ["scratch"])
        )

        let relaunched = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(names(relaunched), ["readme.md", "main.tex"], "Filters persist across launches")

        relaunched.includeExcludedFolder("scratch", forRoot: folder)
        relaunched.setFileType(.plainText, shown: true, forRoot: folder)
        XCTAssertEqual(names(relaunched), ["readme.md", "log.txt", "main.tex", "idea.md"])
    }

    func testRemoteMountSkipsHiddenTypesAndExcludedFoldersWhenSyncing() async throws {
        let transport = MockRemoteTransport()
        let spec = try RemoteMountSpec.parse(connectionString: "dev@desk:/home/dev/ws", targetKind: .folder)
        transport.setRemoteFiles(
            for: spec.id,
            files: [
                "readme.md": "# Readme",
                "out.txt": "log",
                "noisy/a.md": "# A",
                "noisy/b.txt": "b"
            ])
        let defaults = isolatedDefaults()
        let mirror = try makeTemporaryDirectory("FilterMirror")
        let manager = RemoteWorkspaceManager(transport: transport, mirrorBaseDirectory: mirror, userDefaults: defaults)
        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: manager, userDefaults: defaults)
        _ = await vm.connectRemoteMount(spec)
        let rootURL = manager.mirrorRootURL(for: spec)
        let noisyURL = rootURL.appendingPathComponent("noisy", isDirectory: true)
        _ = await manager.loadRemoteDirectory(at: noisyURL)
        let remoteNames = { Set(vm.flatMarkdownFiles.filter(\.isRemote).map(\.name)) }
        XCTAssertEqual(remoteNames(), ["readme.md", "out.txt", "a.md", "b.txt"])

        vm.setFileType(.plainText, shown: false, forRoot: rootURL)
        XCTAssertEqual(remoteNames(), ["readme.md", "a.md"], "Hidden types leave the tree at once")
        transport.resetCallLog()
        _ = await manager.syncMount(id: spec.id)
        XCTAssertEqual(transport.lastListedFileExtensions?.contains("txt"), false, "The listing skips hidden types")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("out.txt").path))

        vm.excludeFolderFromSidebar(noisyURL)
        XCTAssertEqual(remoteNames(), ["readme.md"])
        transport.resetCallLog()
        _ = await manager.syncMount(id: spec.id)
        XCTAssertFalse(transport.listedRelativePaths.contains("noisy"), "Syncs do not list excluded folders")

        let relaunchedManager = RemoteWorkspaceManager(transport: transport, mirrorBaseDirectory: mirror, userDefaults: defaults)
        XCTAssertEqual(
            relaunchedManager.sidebarFilter(for: spec.id),
            SidebarRootFilter(hiddenFileTypes: [.plainText], excludedPaths: ["noisy"])
        )

        vm.includeExcludedFolder("noisy", forRoot: rootURL)
        vm.setFileType(.plainText, shown: true, forRoot: rootURL)
        _ = await manager.syncMount(id: spec.id)
        XCTAssertEqual(remoteNames(), ["readme.md", "out.txt", "a.md", "b.txt"], "Restored folders and types sync again")
    }
}
