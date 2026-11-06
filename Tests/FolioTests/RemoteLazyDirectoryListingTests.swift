import XCTest
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

@MainActor
final class RemoteLazyDirectoryListingTests: XCTestCase {
    private var transport: MockRemoteTransport!
    private var defaults: UserDefaults!
    private var mirror: URL!
    private var spec: RemoteMountSpec!

    override func setUp() async throws {
        transport = MockRemoteTransport()
        defaults = isolatedDefaults()
        mirror = try makeTemporaryDirectory("FolioLazyMirror")
        spec = try RemoteMountSpec.parse(connectionString: "dev@desk:/home/dev/cx-guardrails", targetKind: .folder)
    }

    private func makeViewModel() -> (EditorWorkspaceViewModel, RemoteWorkspaceManager) {
        let manager = RemoteWorkspaceManager(transport: transport, mirrorBaseDirectory: mirror, userDefaults: defaults)
        manager.baseRetryDelaySeconds = 0.01
        return (EditorWorkspaceViewModel(remoteWorkspaceManager: manager, userDefaults: defaults), manager)
    }

    private func mirrorURL(_ relativePath: String, _ manager: RemoteWorkspaceManager) -> URL {
        manager.mirrorRootURL(for: spec).appendingPathComponent(relativePath, isDirectory: true)
    }

    /// The remote root node's descendant at `names`, matched by node name.
    private func node(_ names: [String], in vm: EditorWorkspaceViewModel) -> WorkspaceFileNode? {
        var current = vm.rootFileNodes.first(where: \.isRemoteRoot)
        for name in names {
            current = current?.children?.first(where: { $0.name == name })
        }
        return current
    }

    private func remoteFileNames(_ vm: EditorWorkspaceViewModel) -> Set<String> {
        Set(vm.flatMarkdownFiles.filter(\.isRemote).map(\.name))
    }

    private func isUnlisted(_ node: WorkspaceFileNode?) -> Bool {
        node?.children?.map(\.isLoadingPlaceholder) == [true]
    }

    func testFileBelowDepthFourAppearsAfterEachLevelIsExpanded() async throws {
        let deepPath = "worktrees/api-client-design/src/ProtoCXGuardrails/docs/designs/api-client.md"
        transport.setRemoteFiles(
            for: spec.id,
            files: [
                "worktrees/api-client-design/cr-description.md": "# CR",
                deepPath: "# API client design"
            ])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)

        XCTAssertTrue(isUnlisted(node(["worktrees"], in: vm)), "A subfolder is not listed until it is expanded")
        XCTAssertTrue(remoteFileNames(vm).isEmpty)

        let levels = ["worktrees", "api-client-design", "src", "ProtoCXGuardrails", "docs", "designs"]
        for depth in 1...levels.count {
            let path = levels.prefix(depth).joined(separator: "/")
            XCTAssertTrue(isUnlisted(node(Array(levels.prefix(depth)), in: vm)), "\(path) shows a loading row before it is listed")
            let loaded = await manager.loadRemoteDirectory(at: mirrorURL(path, manager))
            XCTAssertTrue(loaded)
        }

        let designNode = try XCTUnwrap(node(levels + ["api-client.md"], in: vm))
        XCTAssertFalse(designNode.isLoadingPlaceholder)
        XCTAssertEqual(remoteFileNames(vm), ["cr-description.md", "api-client.md"])
        XCTAssertEqual(try String(contentsOf: designNode.url, encoding: .utf8), "# API client design")
    }

    func testListingSkipsIgnoredFoldersAndUnsupportedFiles() async throws {
        transport.setRemoteFiles(
            for: spec.id,
            files: [
                "README.md": "# Root",
                "notes.txt": "plain",
                "image.png": "binary",
                "node_modules/pkg/README.md": "# Dependency",
                ".git/HEAD.md": "ref"
            ])
        let (vm, _) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)

        let rootChildren = try XCTUnwrap(node([], in: vm)?.children)
        XCTAssertEqual(Set(rootChildren.map(\.name)), ["README.md", "notes.txt"])
        XCTAssertEqual(Set(transport.fetchedRelativePaths), ["README.md", "notes.txt"])
    }

    func testSyncDownloadsOnlyFilesWhoseMtimeOrSizeChanged() async throws {
        transport.setRemoteFiles(for: spec.id, files: ["a.md": "# A", "b.md": "# B"])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)
        XCTAssertEqual(Set(transport.fetchedRelativePaths), ["a.md", "b.md"])

        transport.resetCallLog()
        _ = await manager.syncMount(id: spec.id)
        XCTAssertEqual(transport.listedRelativePaths, [""])
        XCTAssertTrue(transport.fetchedRelativePaths.isEmpty, "Unchanged files are not downloaded again")

        transport.setRemoteFiles(for: spec.id, files: ["a.md": "# A edited on the host", "b.md": "# B"])
        transport.resetCallLog()
        _ = await manager.syncMount(id: spec.id)
        XCTAssertEqual(Set(transport.fetchedRelativePaths), ["a.md", "b.md"], "A new mtime triggers a download")
        let aNode = try XCTUnwrap(node(["a.md"], in: vm))
        XCTAssertEqual(try String(contentsOf: aNode.url, encoding: .utf8), "# A edited on the host")
    }

    func testRemoteDeletionPrunesMirrorAndLoadedDirectories() async throws {
        transport.setRemoteFiles(for: spec.id, files: ["keep.md": "# Keep", "old/nested/gone.md": "# Gone"])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)
        _ = await manager.loadRemoteDirectory(at: mirrorURL("old", manager))
        _ = await manager.loadRemoteDirectory(at: mirrorURL("old/nested", manager))
        XCTAssertNotNil(node(["old", "nested", "gone.md"], in: vm))
        XCTAssertEqual(manager.loadedDirectories(for: spec.id), ["", "old", "old/nested"])

        transport.setRemoteFiles(for: spec.id, files: ["keep.md": "# Keep"])
        _ = await manager.syncMount(id: spec.id)

        XCTAssertNil(node(["old"], in: vm))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrorURL("old", manager).path))
        XCTAssertEqual(manager.loadedDirectories(for: spec.id), [""])
        XCTAssertEqual(remoteFileNames(vm), ["keep.md"])
    }

    func testListedDirectoriesPersistAcrossRelaunch() async throws {
        transport.setRemoteFiles(for: spec.id, files: ["docs/guide.md": "# Guide"])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)
        _ = await manager.loadRemoteDirectory(at: mirrorURL("docs", manager))
        XCTAssertNotNil(node(["docs", "guide.md"], in: vm))

        let (relaunchedVM, relaunchedManager) = makeViewModel()
        XCTAssertEqual(relaunchedManager.loadedDirectories(for: spec.id), ["", "docs"])
        _ = await relaunchedManager.syncMount(id: spec.id)
        XCTAssertNotNil(node(["docs", "guide.md"], in: relaunchedVM))
    }

    func testUnlistedFolderWithoutShownDocumentsIsHidden() async throws {
        transport.setRemoteFiles(
            for: spec.id,
            files: [
                "docs/deep/guide.md": "# Guide",
                "logs/deep/run.txt": "log",
                "assets/deep/logo.png": "binary",
                "vendor-cache/node_modules/pkg/README.md": "# Dependency"
            ])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)

        XCTAssertTrue(isUnlisted(node(["docs"], in: vm)))
        XCTAssertTrue(isUnlisted(node(["logs"], in: vm)), "Plain text is shown by default")
        XCTAssertNil(node(["assets"], in: vm), "A folder with no documents at any depth is hidden")
        XCTAssertNil(node(["vendor-cache"], in: vm), "Documents inside ignored folders do not count")

        vm.setFileType(.plainText, shown: false, forRoot: manager.mirrorRootURL(for: spec))
        for _ in 0..<200 where node(["logs"], in: vm) != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(node(["logs"], in: vm), "Hiding a type hides folders that only hold that type, without expanding them")
        XCTAssertTrue(isUnlisted(node(["docs"], in: vm)))
    }

    func testBackgroundSyncReusesFreshProbesAndManualSyncRefreshesThem() async throws {
        transport.setRemoteFiles(for: spec.id, files: ["docs/guide.md": "# Guide", "empty/logo.png": "binary"])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)
        XCTAssertEqual(Set(transport.probedRelativePaths), ["docs", "empty"])

        transport.resetCallLog()
        _ = await manager.syncMount(id: spec.id)
        XCTAssertTrue(transport.probedRelativePaths.isEmpty, "A background sync reuses probes that are still fresh")

        transport.setRemoteFiles(for: spec.id, files: ["docs/guide.md": "# Guide", "empty/new.md": "# New"])
        _ = await manager.syncMount(id: spec.id, isBackground: false)
        XCTAssertEqual(Set(transport.probedRelativePaths), ["docs", "empty"])
        XCTAssertTrue(isUnlisted(node(["empty"], in: vm)), "A manual sync finds new documents in a hidden folder")

        manager.directoryProbeLifetimeSeconds = 0
        transport.setRemoteFiles(for: spec.id, files: ["docs/guide.md": "# Guide", "empty/logo.png": "binary"])
        _ = await manager.syncMount(id: spec.id)
        XCTAssertNil(node(["empty"], in: vm), "An expired probe is checked again during a background sync")
    }

    func testFailedLoadKeepsLoadingRowUntilReconnect() async throws {
        transport.setRemoteFiles(for: spec.id, files: ["docs/guide.md": "# Guide"])
        let (vm, manager) = makeViewModel()
        _ = await vm.connectRemoteMount(spec)

        transport.simulatedError = RemoteWorkspaceError.transportTimeout(host: "desk")
        let loaded = await manager.loadRemoteDirectory(at: mirrorURL("docs", manager))
        XCTAssertFalse(loaded)
        XCTAssertTrue(isUnlisted(node(["docs"], in: vm)), "A failed load keeps the loading row")

        transport.simulatedError = nil
        for _ in 0..<200 where node(["docs", "guide.md"], in: vm) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(node(["docs", "guide.md"], in: vm), "The automatic retry lists the folder")
        XCTAssertEqual(manager.connectionStates[spec.id], .connected)
    }
}
