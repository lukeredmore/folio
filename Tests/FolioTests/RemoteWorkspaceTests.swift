import AppKit
import SwiftUI
import XCTest
@testable import Folio

final class RemoteWorkspaceTests: XCTestCase {

    func testRemoteMountSpecParsingAndSSHHelpers() throws {
        // 1. Standard scp-style user@host:/path
        let spec1 = try RemoteMountSpec.parse(
            connectionString: "luke@devbox.internal:/home/luke/notes",
            targetKind: .folder
        )
        XCTAssertEqual(spec1.user, "luke")
        XCTAssertEqual(spec1.host, "devbox.internal")
        XCTAssertEqual(spec1.port, 22)
        XCTAssertEqual(spec1.remotePath, "/home/luke/notes")
        XCTAssertEqual(spec1.targetKind, .folder)
        XCTAssertEqual(spec1.sshDestination, "luke@devbox.internal")
        XCTAssertEqual(spec1.label, "notes (devbox.internal)")

        // 2. Tilde path without explicit user
        let spec2 = try RemoteMountSpec.parse(
            connectionString: "prod-server:~/runbooks/incident.md",
            targetKind: .file,
            portOverride: 2222,
            displayName: "Prod Incident Runbook"
        )
        XCTAssertNil(spec2.user)
        XCTAssertEqual(spec2.host, "prod-server")
        XCTAssertEqual(spec2.port, 2222)
        XCTAssertEqual(spec2.remotePath, "~/runbooks/incident.md")
        XCTAssertEqual(spec2.targetKind, .file)
        XCTAssertEqual(spec2.label, "Prod Incident Runbook")

        // 3. ssh:// URL with port and tilde path
        let spec3 = try RemoteMountSpec.parse(
            connectionString: "ssh://ubuntu@10.0.1.42:2200/~/workspace/docs",
            targetKind: .folder
        )
        XCTAssertEqual(spec3.user, "ubuntu")
        XCTAssertEqual(spec3.host, "10.0.1.42")
        XCTAssertEqual(spec3.port, 2200)
        XCTAssertEqual(spec3.remotePath, "~/workspace/docs")

        // 4. Invalid connection string throws descriptive error
        XCTAssertThrowsError(try RemoteMountSpec.parse(connectionString: "invalid_missing_colon", targetKind: .folder))

        // 5. SSH shell escaping & snapshot parser
        XCTAssertEqual(SSHRemoteTransport.shellEscapePath("~/my notes/todo.md"), "\"$HOME\"/'my notes/todo.md'")
        XCTAssertEqual(SSHRemoteTransport.shellEscapePath("/var/docs/readme.md"), "'/var/docs/readme.md'")

        let rawContent1 = Data("# Remote Readme\nHello from SSH!\n".utf8).base64EncodedString()
        let rawContent2 = Data("## Subfolder Note\nFast local mirror.".utf8).base64EncodedString()
        let sampleStream = """
        ===FOLIO_FILE===\tREADME.md\t1729300000
        \(rawContent1)
        ===FOLIO_END===
        ===FOLIO_FILE===\tguides/setup.md\t1729300500
        \(rawContent2)
        ===FOLIO_END===
        """
        let entries = SSHRemoteTransport.parseSnapshotOutput(sampleStream)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].relativePath, "README.md")
        XCTAssertEqual(entries[0].content, "# Remote Readme\nHello from SSH!\n")
        XCTAssertEqual(entries[1].relativePath, "guides/setup.md")
        XCTAssertEqual(entries[1].content, "## Subfolder Note\nFast local mirror.")
    }

    @MainActor
    func testRemoteWorkspaceFolderAndFileMountUnifiedTreeAndSelfHealingSync() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FolioRemoteTest_\(UUID().uuidString)", isDirectory: true)
        let localWorkspaceDir = tempRoot.appendingPathComponent("LocalNotes", isDirectory: true)
        let mirrorBaseDir = tempRoot.appendingPathComponent("Mirrors", isDirectory: true)
        try FileManager.default.createDirectory(at: localWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirrorBaseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let defaultsSuiteName = "com.folio.tests.remote.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        defer { testDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        // Create a local file
        let localFileURL = localWorkspaceDir.appendingPathComponent("local_todo.md")
        try "# Local Todo\nBuy coffee and write Rust.".write(to: localFileURL, atomically: true, encoding: .utf8)

        // Configure MockRemoteTransport with a remote folder and a remote single file
        let mockTransport = MockRemoteTransport()
        let folderSpec = try RemoteMountSpec.parse(
            connectionString: "luke@devbox:/home/luke/cloud_notes",
            targetKind: .folder
        )
        let singleFileSpec = try RemoteMountSpec.parse(
            connectionString: "ops@prod:/etc/folio/runbook.md",
            targetKind: .file
        )

        mockTransport.setRemoteFiles(for: folderSpec.id, files: [
            "index.md": "# Cloud Index\nWelcome to remote folder sync.",
            "architecture/design.md": "# Distributed Sync\nFeels like local disk speed."
        ])
        mockTransport.setRemoteFiles(for: singleFileSpec.id, files: [
            "runbook.md": "# Prod Runbook\nAll systems nominal."
        ])

        let remoteManager = RemoteWorkspaceManager(
            transport: mockTransport,
            mirrorBaseDirectory: mirrorBaseDir,
            userDefaults: testDefaults
        )
        remoteManager.baseRetryDelaySeconds = 0.05

        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: remoteManager)
        vm.loadWorkspaceFolder(localWorkspaceDir)

        // Connect both the remote folder and the remote single file
        await vm.connectRemoteMount(folderSpec)
        await vm.connectRemoteMount(singleFileSpec)

        // 1. Verify unified multi-root sidebar tree & flatMarkdownFiles include local + remote folder + remote file
        let allFlatNames = Set(vm.flatMarkdownFiles.map(\.name))
        XCTAssertEqual(allFlatNames, ["local_todo.md", "index.md", "design.md", "runbook.md"])

        let remoteRootNodes = vm.rootFileNodes.filter(\.isRemoteRoot)
        XCTAssertEqual(remoteRootNodes.count, 2, "Expected 1 remote folder root and 1 remote single-file root in sidebar")
        XCTAssertEqual(remoteManager.connectionStates[folderSpec.id], .connected)
        XCTAssertEqual(remoteManager.connectionStates[singleFileSpec.id], .connected)
        XCTAssertTrue(remoteManager.unhealthyMounts.isEmpty)

        // 2. Verify Workspace Search works across both local and remote mirrored files at local speed
        vm.workspaceSearchQuery = "Distributed Sync"
        vm.performWorkspaceSearch()
        XCTAssertEqual(vm.workspaceSearchMatches.count, 1)
        XCTAssertEqual(vm.workspaceSearchMatches.first?.fileName, "design.md")

        // 3. Open remote file, edit, and save while connected -> instant local mirror update + remote push
        let designNode = try XCTUnwrap(vm.flatMarkdownFiles.first(where: { $0.name == "design.md" }))
        vm.openFile(at: designNode.url)
        XCTAssertEqual(vm.markdownText, "# Distributed Sync\nFeels like local disk speed.")

        vm.markdownText = "# Distributed Sync\nUpdated from native macOS editor!"
        vm.saveDocument()
        XCTAssertFalse(vm.isDirty)

        // Wait for the async save task to push to MockRemoteTransport
        for _ in 0..<50 {
            if mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md") == "# Distributed Sync\nUpdated from native macOS editor!"
                && remoteManager.syncStatus(forLocalURL: designNode.url) == .synced {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md"),
            "# Distributed Sync\nUpdated from native macOS editor!"
        )
        XCTAssertEqual(remoteManager.syncStatus(forLocalURL: designNode.url), .synced)

        // 4. Create a new file inside the remote folder -> created locally and pushed to remote
        let remoteFolderRootURL = remoteManager.mirrorRootURL(for: folderSpec)
        vm.createNewFileInWorkspace(in: remoteFolderRootURL)
        for _ in 0..<50 {
            if mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "Untitled.md") != nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(
            mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "Untitled.md"),
            "Newly created file inside remote folder should be pushed to remote host"
        )

        // 5. Simulate connection drop -> edit & save while offline -> clear error state + queued offline edit
        mockTransport.simulatedError = RemoteWorkspaceError.connectionFailed(
            host: "devbox",
            details: "ssh: connect to host devbox port 22: Operation timed out"
        )

        vm.openFile(at: designNode.url)
        vm.markdownText = "# Distributed Sync\nEdited while offline on airplane Wi-Fi!"
        vm.saveDocument()
        XCTAssertFalse(vm.isDirty, "Saving a remote file while offline must still succeed locally without blocking the user")

        for _ in 0..<50 {
            if remoteManager.syncStatus(forLocalURL: designNode.url) == .pendingUpload && !remoteManager.unhealthyMounts.isEmpty {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Verify file is marked pendingUpload and mount state is .reconnecting with clear error
        XCTAssertEqual(remoteManager.syncStatus(forLocalURL: designNode.url), .pendingUpload)
        XCTAssertEqual(remoteManager.unhealthyMounts.count, 1)
        XCTAssertEqual(remoteManager.unhealthyMounts.first?.0.id, folderSpec.id)
        XCTAssertTrue(remoteManager.unhealthyMounts.first?.1.errorMessage?.contains("Operation timed out") ?? false)

        // 6. Simulate connection recovery -> self-healing reconnect flushes pending queue and clears error state automatically
        mockTransport.simulatedError = nil
        for _ in 0..<100 {
            if remoteManager.connectionStates[folderSpec.id] == .connected
                && remoteManager.syncStatus(forLocalURL: designNode.url) == .synced {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(
            remoteManager.connectionStates[folderSpec.id],
            .connected,
            "Connection state should automatically self-heal to .connected once transport succeeds"
        )
        XCTAssertTrue(
            remoteManager.unhealthyMounts.isEmpty,
            "Unhealthy mounts banner should automatically clear once reconnected"
        )
        XCTAssertEqual(
            remoteManager.syncStatus(forLocalURL: designNode.url),
            .synced,
            "Queued offline edit should transition to .synced after self-healing reconnect"
        )
        XCTAssertEqual(
            mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md"),
            "# Distributed Sync\nEdited while offline on airplane Wi-Fi!",
            "Queued offline edit must be flushed to the remote server upon reconnection"
        )
    }
}
