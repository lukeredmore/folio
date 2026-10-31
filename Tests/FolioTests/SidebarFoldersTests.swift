import XCTest
@testable import Folio

@MainActor
final class SidebarFoldersTests: XCTestCase {

    private func makeFolder(_ name: String, files: [String]) throws -> URL {
        let folder = try makeTemporaryDirectory(name)
        for file in files {
            try "# \(file)\n".write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return folder
    }

    func testAddingFoldersShowsEachAsASidebarRoot() throws {
        let alpha = try makeFolder("Alpha", files: ["a.md"])
        let beta = try makeFolder("Beta", files: ["b.md"])
        let vm = makeIsolatedViewModel()

        vm.loadWorkspaceFolder(alpha)
        vm.loadWorkspaceFolder(beta)

        let roots = vm.rootFileNodes.filter(\.isLocalRoot)
        XCTAssertEqual(Set(roots.map(\.url.standardizedFileURL)), [alpha.standardizedFileURL, beta.standardizedFileURL])
        XCTAssertEqual(Set(vm.flatMarkdownFiles.map(\.name)), ["a.md", "b.md"])
        XCTAssertEqual(vm.workspaceFolderURL?.standardizedFileURL, beta.standardizedFileURL, "The last added folder is primary")
    }

    func testAddingANestedOrParentFolderKeepsOneRoot() throws {
        let parent = try makeFolder("Parent", files: ["top.md"])
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "# Child\n".write(to: child.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        let vm = makeIsolatedViewModel()

        vm.loadWorkspaceFolder(child)
        vm.loadWorkspaceFolder(parent)
        XCTAssertEqual(vm.sidebarLocalFolderURLs, [parent.standardizedFileURL])

        vm.loadWorkspaceFolder(child)
        XCTAssertEqual(vm.sidebarLocalFolderURLs, [parent.standardizedFileURL])
        XCTAssertEqual(Set(vm.flatMarkdownFiles.map(\.name)), ["top.md", "c.md"])
    }

    func testRemovingAFolderLeavesFilesOnDisk() throws {
        let alpha = try makeFolder("Alpha", files: ["a.md"])
        let beta = try makeFolder("Beta", files: ["b.md"])
        let vm = makeIsolatedViewModel()
        vm.loadWorkspaceFolder(alpha)
        vm.loadWorkspaceFolder(beta)

        vm.removeLocalFolder(beta)

        XCTAssertEqual(vm.sidebarLocalFolderURLs, [alpha.standardizedFileURL])
        XCTAssertEqual(vm.workspaceFolderURL?.standardizedFileURL, alpha.standardizedFileURL)
        XCTAssertEqual(vm.flatMarkdownFiles.map(\.name), ["a.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.appendingPathComponent("b.md").path))
    }

    func testFoldersPersistAcrossLaunches() throws {
        let alpha = try makeFolder("Alpha", files: ["a.md"])
        let beta = try makeFolder("Beta", files: ["b.md"])
        let defaults = isolatedDefaults()
        do {
            let vm = makeIsolatedViewModel(defaults: defaults)
            vm.loadWorkspaceFolder(alpha)
            vm.loadWorkspaceFolder(beta)
        }

        let relaunched = makeIsolatedViewModel(defaults: defaults)
        XCTAssertEqual(
            Set(relaunched.sidebarLocalFolderURLs),
            [alpha.standardizedFileURL, beta.standardizedFileURL]
        )
        XCTAssertEqual(Set(relaunched.flatMarkdownFiles.map(\.name)), ["a.md", "b.md"])
    }

    func testCLIFileInsideAnyFolderDoesNotAddAFolder() throws {
        let alpha = try makeFolder("Alpha", files: ["a.md"])
        let beta = try makeFolder("Beta", files: ["b.md"])
        let vm = makeIsolatedViewModel()
        vm.loadWorkspaceFolder(alpha)
        vm.loadWorkspaceFolder(beta)

        vm.openPathFromCLI(alpha.appendingPathComponent("a.md").path)

        XCTAssertEqual(vm.sidebarLocalFolderURLs.count, 2)
        XCTAssertEqual(vm.currentFileURL?.lastPathComponent, "a.md")
    }

    func testLocalAndRemoteRootsSortTogetherByName() {
        let date = Date()
        func root(_ name: String, remote: Bool) -> WorkspaceFileNode {
            WorkspaceFileNode(
                url: URL(fileURLWithPath: "/roots/\(name)"),
                name: name,
                isDirectory: true,
                modificationDate: date,
                creationDate: date,
                children: [],
                remoteMountID: remote ? UUID() : nil,
                isRemoteRoot: remote,
                isLocalRoot: !remote
            )
        }
        let vm = makeIsolatedViewModel()
        let sorted = vm.sortNodesArray(
            [root("zeta", remote: false), root("beta", remote: true), root("alpha", remote: false)],
            by: .modificationDate
        )
        XCTAssertEqual(sorted.map(\.name), ["alpha", "beta", "zeta"])
    }
}

final class RemoteHostEntryTests: XCTestCase {

    func testHostAndPathParseSeparately() throws {
        let spec = try RemoteMountSpec.parse(destination: "luke@devbox", path: "/home/luke/notes")
        XCTAssertEqual(spec.user, "luke")
        XCTAssertEqual(spec.host, "devbox")
        XCTAssertEqual(spec.remotePath, "/home/luke/notes")
        XCTAssertEqual(spec.targetKind, .folder)
        XCTAssertEqual(spec.folderName, "notes")

        let home = try RemoteMountSpec.parse(destination: "devbox", path: "")
        XCTAssertEqual(home.remotePath, "~")

        let pasted = try RemoteMountSpec.parse(destination: "luke@devbox:~/paper/main.tex", path: "")
        XCTAssertEqual(pasted.host, "devbox")
        XCTAssertEqual(pasted.remotePath, "~/paper/main.tex")
        XCTAssertEqual(pasted.targetKind, .file, "A LaTeX path mounts as a single file")

        XCTAssertThrowsError(try RemoteMountSpec.parse(destination: " ", path: "/notes"))
    }

    @MainActor
    func testRecentHostsListMostRecentFirstWithSettings() throws {
        let manager = RemoteWorkspaceManager(
            transport: MockRemoteTransport(),
            mirrorBaseDirectory: try makeTemporaryDirectory("FolioMirror"),
            userDefaults: isolatedDefaults()
        )
        manager.recordRecentHost(RemoteMountSpec(host: "alpha", user: "luke", port: 22, remotePath: "~/a"))
        manager.recordRecentHost(
            RemoteMountSpec(host: "beta", port: 2222, remotePath: "~/b", identityFile: "~/.ssh/beta")
        )
        manager.recordRecentHost(RemoteMountSpec(host: "alpha", user: "luke", port: 22, remotePath: "~/c"))

        XCTAssertEqual(manager.recentHosts.map { $0.id }, ["luke@alpha", "beta:2222"])
        XCTAssertEqual(manager.recentHosts.last?.identityFile, "~/.ssh/beta")
    }
}
