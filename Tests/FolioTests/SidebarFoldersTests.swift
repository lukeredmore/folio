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

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    func testRefreshFolderFromDiskUpdatesTreeSearchAndOpenDocument() throws {
        let folder = try makeFolder("RefreshManual", files: ["existing.md"])
        let vm = makeIsolatedViewModel()
        vm.loadWorkspaceFolder(folder)

        let existingURL = folder.appendingPathComponent("existing.md")
        vm.openFile(at: existingURL)
        vm.workspaceSearchQuery = "needle"
        vm.performWorkspaceSearch()
        XCTAssertTrue(vm.workspaceSearchMatches.isEmpty)

        // Cancel automatic watcher so we specifically test manual refreshFolderFromDisk
        vm.stopWatchingWorkspaceFolders()
        vm.stopWatchingCurrentFile()

        let addedURL = folder.appendingPathComponent("added.md")
        try "# Added\nFound a needle here.\n".write(to: addedURL, atomically: true, encoding: .utf8)
        try "# Existing\nUpdated externally with needle.\n".write(to: existingURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(vm.flatMarkdownFiles.map(\.name), ["existing.md"])

        vm.refreshFolderFromDisk(folder)

        XCTAssertEqual(Set(vm.flatMarkdownFiles.map(\.name)), ["existing.md", "added.md"])
        XCTAssertEqual(Set(vm.workspaceSearchMatches.map(\.fileName)), ["existing.md", "added.md"])
        XCTAssertTrue(vm.markdownText.contains("Updated externally with needle."))
    }

    func testWorkspaceFoldersAutomaticallyRefreshOnDiskChanges() throws {
        let folder = try makeFolder("AutoWatch", files: ["alpha.md"])
        let emptySubfolder = folder.appendingPathComponent("empty-sub", isDirectory: true)
        try FileManager.default.createDirectory(at: emptySubfolder, withIntermediateDirectories: true)

        let vm = makeIsolatedViewModel()
        vm.loadWorkspaceFolder(folder)
        vm.workspaceSearchQuery = "magic-token"
        vm.performWorkspaceSearch()
        XCTAssertEqual(vm.flatMarkdownFiles.map(\.name), ["alpha.md"])
        XCTAssertTrue(vm.workspaceSearchMatches.isEmpty)

        // 1. Adding a file in the root folder updates the tree and active search automatically.
        let betaURL = folder.appendingPathComponent("beta.md")
        try "# Beta\nContains magic-token.\n".write(to: betaURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            waitUntil { Set(vm.flatMarkdownFiles.map(\.name)) == ["alpha.md", "beta.md"] },
            "Adding a file to a watched root folder should automatically update the sidebar tree"
        )
        XCTAssertEqual(vm.workspaceSearchMatches.map(\.fileName), ["beta.md"])

        // 2. Adding a file inside an initially-empty subfolder makes the subfolder and file appear automatically.
        let nestedURL = emptySubfolder.appendingPathComponent("nested.md")
        try "# Nested\nAnother magic-token.\n".write(to: nestedURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            waitUntil { Set(vm.flatMarkdownFiles.map(\.name)) == ["alpha.md", "beta.md", "nested.md"] },
            "Adding a file to an existing empty subfolder should automatically reveal the subfolder and file"
        )
        XCTAssertEqual(Set(vm.workspaceSearchMatches.map(\.fileName)), ["beta.md", "nested.md"])

        // 3. Creating a brand-new subfolder and writing a file inside it updates the sidebar automatically.
        let newSubfolder = folder.appendingPathComponent("brand-new-sub", isDirectory: true)
        try FileManager.default.createDirectory(at: newSubfolder, withIntermediateDirectories: true)
        let deepURL = newSubfolder.appendingPathComponent("deep.tex")
        try "\\section{Deep}\n% magic-token\n".write(to: deepURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            waitUntil { Set(vm.flatMarkdownFiles.map(\.name)) == ["alpha.md", "beta.md", "nested.md", "deep.tex"] },
            "Creating a new subfolder with a supported document should automatically update the sidebar"
        )

        // 4. Renaming and deleting files on disk updates the sidebar automatically.
        let renamedURL = folder.appendingPathComponent("beta-renamed.md")
        try FileManager.default.moveItem(at: betaURL, to: renamedURL)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("alpha.md"))

        XCTAssertTrue(
            waitUntil { Set(vm.flatMarkdownFiles.map(\.name)) == ["beta-renamed.md", "nested.md", "deep.tex"] },
            "Renaming and deleting files on disk should automatically update the sidebar"
        )

        // 5. Removing the folder from the sidebar stops watching it.
        vm.removeLocalFolder(folder)
        XCTAssertTrue(vm.folderWatchEntries.isEmpty)
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
