import AppKit
import XCTest
@testable import Folio

@MainActor
final class WorkspaceFileDeletionTests: XCTestCase {

    private func makeWorkspace() throws -> (vm: EditorWorkspaceViewModel, dir: URL) {
        let dir = try makeTemporaryDirectory("FolioDeletionTest")
        try "# Existing\n\nBody".write(to: dir.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8)
        let vm = makeIsolatedViewModel()
        vm.autoSaveDelay = 0
        vm.openFolder(at: dir)
        return (vm, dir)
    }

    func testUntouchedNewFileIsDeletedWhenSwitchingAway() throws {
        let (vm, dir) = try makeWorkspace()
        let untitled = dir.appendingPathComponent("Untitled.md")

        vm.createNewFileInWorkspace(in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: untitled.path))

        vm.openFile(at: dir.appendingPathComponent("Existing.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: untitled.path), "Unedited new file should be deleted")
        XCTAssertFalse(vm.flatMarkdownFiles.contains(where: { $0.name == "Untitled.md" }))
    }

    func testRepeatedNewFileDoesNotAccumulateUntitledCopies() throws {
        let (vm, dir) = try makeWorkspace()

        vm.createNewFileInWorkspace(in: dir)
        vm.createNewFileInWorkspace(in: dir)
        vm.newDocument()

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("Untitled") }, [])
    }

    func testEditedNewFileIsKept() throws {
        let (vm, dir) = try makeWorkspace()
        let untitled = dir.appendingPathComponent("Untitled.md")

        vm.createNewFileInWorkspace(in: dir)
        vm.handleEditorTextEdited("# Untitled\n\nReal notes", selectedRange: NSRange(location: 0, length: 0))
        vm.openFile(at: dir.appendingPathComponent("Existing.md"))

        XCTAssertEqual(try String(contentsOf: untitled, encoding: .utf8), "# Untitled\n\nReal notes")
    }

    func testUntouchedNewLaTeXFileIsDeletedOnNewDocument() throws {
        let (vm, dir) = try makeWorkspace()
        let untitled = dir.appendingPathComponent("Untitled.tex")

        vm.createNewLaTeXFileInWorkspace(in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: untitled.path))
        vm.newDocument()
        XCTAssertFalse(FileManager.default.fileExists(atPath: untitled.path))
    }

    func testSidebarDeletionRules() {
        let local = WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/a.md"), name: "a.md", isDirectory: false, modificationDate: Date(), creationDate: Date(), children: nil)
        let localFolder = WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/dir"), name: "dir", isDirectory: true, modificationDate: Date(), creationDate: Date(), children: [])
        let remoteFile = WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/r.md"), name: "r.md", isDirectory: false, modificationDate: Date(), creationDate: Date(), children: nil,
            remoteMountID: UUID())
        let remoteFolder = WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/rd"), name: "rd", isDirectory: true, modificationDate: Date(), creationDate: Date(), children: [],
            remoteMountID: UUID())
        let remoteRoot = WorkspaceFileNode(
            url: URL(fileURLWithPath: "/tmp/root"), name: "root", isDirectory: true, modificationDate: Date(), creationDate: Date(), children: [],
            remoteMountID: UUID(), isRemoteRoot: true)

        XCTAssertTrue(local.isDeletableFromSidebar)
        XCTAssertTrue(localFolder.isDeletableFromSidebar)
        XCTAssertTrue(remoteFile.isDeletableFromSidebar)
        XCTAssertFalse(remoteFolder.isDeletableFromSidebar)
        XCTAssertFalse(remoteRoot.isDeletableFromSidebar)
    }

    func testDeleteRemoteFileRemovesHostCopyAndMirror() async throws {
        let tempRoot = try makeTemporaryDirectory("FolioRemoteDelete")
        let defaults = isolatedDefaults()

        let transport = MockRemoteTransport()
        let spec = try RemoteMountSpec.parse(connectionString: "luke@devbox:/home/luke/notes", targetKind: .folder)
        transport.setRemoteFiles(for: spec.id, files: ["keep.md": "# Keep", "drop.md": "# Drop"])
        let manager = RemoteWorkspaceManager(transport: transport, mirrorBaseDirectory: tempRoot, userDefaults: defaults)
        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: manager)
        await vm.connectRemoteMount(spec)

        let mirrored = manager.mirrorRootURL(for: spec).appendingPathComponent("drop.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrored.path))
        try await manager.deleteRemoteFile(at: mirrored)

        XCTAssertNil(transport.getRemoteFile(for: spec.id, relativePath: "drop.md"))
        XCTAssertNotNil(transport.getRemoteFile(for: spec.id, relativePath: "keep.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mirrored.path))
    }
}
