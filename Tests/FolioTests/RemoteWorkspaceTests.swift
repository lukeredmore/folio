import AppKit
import SwiftUI
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

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

        // 6. Directory listing parser
        let listingStream = """
            ===FOLIO_DIR===\t
            D\tworktrees
            F\tREADME.md\t1729300000 42
            ===FOLIO_MISSING===\tgone
            ===FOLIO_DIR===\tworktrees/api client
            F\tnotes.md\t1729300500 7
            """
        XCTAssertEqual(
            SSHRemoteTransport.parseDirectoryListingOutput(listingStream),
            [
                RemoteDirectoryListing(
                    relativePath: "",
                    exists: true,
                    subdirectoryNames: ["worktrees"],
                    files: [RemoteFileStat(name: "README.md", modificationTimestamp: 1_729_300_000, size: 42)]
                ),
                RemoteDirectoryListing(relativePath: "gone", exists: false, subdirectoryNames: [], files: []),
                RemoteDirectoryListing(
                    relativePath: "worktrees/api client",
                    exists: true,
                    subdirectoryNames: [],
                    files: [RemoteFileStat(name: "notes.md", modificationTimestamp: 1_729_300_500, size: 7)]
                )
            ]
        )
        let pattern = SSHRemoteTransport.documentNameCasePattern(for: WorkspaceFileNode.remoteDocumentExtensions)
        XCTAssertTrue(pattern.contains("*.[mM][dD]"))
        XCTAssertFalse(pattern.contains("textbundle"))
        XCTAssertEqual(SSHRemoteTransport.documentNameCasePattern(for: ["md", "txt"]), "*.[mM][dD]|*.[tT][xX][tT]")
        XCTAssertEqual(SSHRemoteTransport.documentNameCasePattern(for: []), "__folio_no_documents__")

        // 7. Directory probe parser and find arguments
        XCTAssertEqual(
            SSHRemoteTransport.parseProbeOutput("===FOLIO_PROBE===\tdocs\t1\n===FOLIO_PROBE===\tlogs/old\t0\nnoise\n"),
            ["docs": true, "logs/old": false]
        )
        let findArguments = SSHRemoteTransport.probeFindArguments(fileExtensions: ["md", "txt"], excludedPaths: ["logs/old"])
        XCTAssertTrue(findArguments.hasPrefix("\\( -name '.*' -o -name 'bazel-*' -o -name '*.app' -o -name '.build'"))
        XCTAssertTrue(findArguments.hasSuffix("-o -path 'logs/old' \\) -prune -o -type f \\( -iname '*.md' -o -iname '*.txt' \\) -print"))
    }

    @MainActor
    func testRemoteWorkspaceFolderAndFileMountUnifiedTreeAndSelfHealingSync() async throws {
        let tempRoot = try makeTemporaryDirectory("FolioRemoteTest")
        let localWorkspaceDir = tempRoot.appendingPathComponent("LocalNotes", isDirectory: true)
        let mirrorBaseDir = tempRoot.appendingPathComponent("Mirrors", isDirectory: true)
        try FileManager.default.createDirectory(at: localWorkspaceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mirrorBaseDir, withIntermediateDirectories: true)

        let testDefaults = isolatedDefaults()

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

        mockTransport.setRemoteFiles(
            for: folderSpec.id,
            files: [
                "index.md": "# Cloud Index\nWelcome to remote folder sync.",
                "architecture/design.md": "# Distributed Sync\nFeels like local disk speed."
            ])
        mockTransport.setRemoteFiles(
            for: singleFileSpec.id,
            files: [
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

        // 1. Verify unified multi-root sidebar tree & flatMarkdownFiles include local + remote folder + remote file.
        // A remote subfolder is listed only after it is expanded.
        XCTAssertEqual(Set(vm.flatMarkdownFiles.map(\.name)), ["local_todo.md", "index.md", "runbook.md"])
        let architectureURL = remoteManager.mirrorRootURL(for: folderSpec).appendingPathComponent("architecture", isDirectory: true)
        let architectureLoaded = await remoteManager.loadRemoteDirectory(at: architectureURL)
        XCTAssertTrue(architectureLoaded)
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
            if mockTransport.getRemoteFile(for: folderSpec.id, relativePath: "architecture/design.md")
                == "# Distributed Sync\nUpdated from native macOS editor!"
                && remoteManager.syncStatus(forLocalURL: designNode.url) == .synced
            {
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
                && remoteManager.syncStatus(forLocalURL: designNode.url) == .synced
            {
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

    @MainActor
    func testSSHRemoteTransportPreservesLaTeXAndBibFilesAndAvoidsPipeDeadlock() async throws {
        let tempRoot = try makeTemporaryDirectory("FolioSSHShimTest")
        let remoteFolder = tempRoot.appendingPathComponent("remote-repo", isDirectory: true)
        let nestedTexDir = remoteFolder.appendingPathComponent("chapters", isDirectory: true)
        let mirrorBase = tempRoot.appendingPathComponent("local-mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedTexDir, withIntermediateDirectories: true)

        let texURL = remoteFolder.appendingPathComponent("paper.tex")
        let latexURL = remoteFolder.appendingPathComponent("appendix.latex")
        let styURL = remoteFolder.appendingPathComponent("macros.sty")
        let bibURL = remoteFolder.appendingPathComponent("references.bib")
        let mdURL = remoteFolder.appendingPathComponent("README.md")
        let nestedChapterURL = nestedTexDir.appendingPathComponent("intro.tex")

        try "\\documentclass{article}\n\\begin{document}\nInitial\\end{document}\n"
            .write(to: texURL, atomically: true, encoding: .utf8)
        try "\\section{Appendix}\n".write(to: latexURL, atomically: true, encoding: .utf8)
        try "\\ProvidesPackage{macros}\n".write(to: styURL, atomically: true, encoding: .utf8)
        try "@article{folio2026, title={Folio}}\n".write(to: bibURL, atomically: true, encoding: .utf8)
        try "# Project Notes\n".write(to: mdURL, atomically: true, encoding: .utf8)
        try "\\section{Intro}\n".write(to: nestedChapterURL, atomically: true, encoding: .utf8)

        let commandLogURL = tempRoot.appendingPathComponent("ssh-commands.log")
        let sshShimURL = tempRoot.appendingPathComponent("ssh-shim.sh")
        let shimScript = """
            #!/bin/sh
            set -eu
            SAW_DOUBLE_DASH=0
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--" ]; then
                    SAW_DOUBLE_DASH=1
                    shift
                    break
                fi
                shift
            done
            if [ "$SAW_DOUBLE_DASH" != "1" ]; then
                echo "Missing -- before SSH destination" >&2
                exit 64
            fi
            DEST="$1"
            shift
            CMD="$*"
            printf '%s\\n---CMD---\\n' "$CMD" >> "\(commandLogURL.path)"
            head -c 98304 /dev/zero | tr '\\0' 'w' >&2
            exec /bin/sh -c "$CMD"
            """
        try shimScript.write(to: sshShimURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sshShimURL.path)

        let sshTransport = SSHRemoteTransport(connectTimeoutSeconds: 5, sshExecutableURL: sshShimURL)
        let mountSpec = RemoteMountSpec(
            host: "localhost",
            user: "researcher",
            remotePath: remoteFolder.path,
            targetKind: .folder
        )

        let listings = try await sshTransport.listDirectories([""], for: mountSpec)
        let listedNames = Set(listings.first?.files.map(\.name) ?? [])
        XCTAssertEqual(
            listedNames,
            ["README.md", "appendix.latex", "macros.sty", "paper.tex", "references.bib"],
            "SSHRemoteTransport.listDirectories must include .tex, .latex, .sty, and .bib alongside Markdown"
        )
        let probes = try await sshTransport.probeDirectories(["chapters"], for: mountSpec)
        XCTAssertEqual(probes["chapters"], true, "SSHRemoteTransport.probeDirectories must detect .tex-only subdirectories")

        let defaults = isolatedDefaults()
        let remoteManager = RemoteWorkspaceManager(
            transport: sshTransport,
            mirrorBaseDirectory: mirrorBase,
            userDefaults: defaults
        )
        defer { remoteManager.stopBackgroundSyncLoop() }

        let added = await remoteManager.addMount(mountSpec)
        XCTAssertTrue(added)

        let localTexURL = remoteManager.mirrorRootURL(for: mountSpec).appendingPathComponent("paper.tex")
        let localBibURL = remoteManager.mirrorRootURL(for: mountSpec).appendingPathComponent("references.bib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: localTexURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localBibURL.path))

        // Push a >128 KB .tex payload while the shim simultaneously emits >96 KB on stderr.
        let largeBody = String(repeating: "% Section content line for pipe backpressure verification.\n", count: 2500)
        let updatedTex = "\\documentclass{article}\n\\begin{document}\n\(largeBody)\\end{document}\n"
        XCTAssertGreaterThan(updatedTex.utf8.count, 131_072)
        let updatedBib = "@article{folio2026, title={Folio Updated}}\n"

        await remoteManager.saveRemoteFile(at: localTexURL, content: updatedTex)
        await remoteManager.saveRemoteFile(at: localBibURL, content: updatedBib)
        XCTAssertEqual(remoteManager.syncStatus(forLocalURL: localTexURL), .synced)
        XCTAssertEqual(remoteManager.syncStatus(forLocalURL: localBibURL), .synced)

        // Subsequent sync must NOT delete saved .tex or .bib files from local mirror!
        _ = await remoteManager.syncMount(id: mountSpec.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: localTexURL.path),
            "Reconciling local mirror after sync must preserve .tex files"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: localBibURL.path),
            "Reconciling local mirror after sync must preserve .bib files"
        )
        XCTAssertEqual(try String(contentsOf: texURL, encoding: .utf8), updatedTex)
        XCTAssertEqual(try String(contentsOf: bibURL, encoding: .utf8), updatedBib)

        let loggedCommands = try String(contentsOf: commandLogURL, encoding: .utf8)
        let samplePayloadPrefix = Data(updatedTex.utf8).base64EncodedString().prefix(64)
        XCTAssertFalse(
            loggedCommands.contains(samplePayloadPrefix),
            "pushFile must stream base64 payload once via stdin instead of interpolating it into the shell command"
        )
    }

    @MainActor
    func testSaveRemoteFilePreservesNewerQueuedRevisionDuringInFlightPush() async throws {
        let transport = GatedPushRemoteTransport()
        let tempMirror = try makeTemporaryDirectory("FolioQueueRaceMirror")
        let defaults = isolatedDefaults()
        let spec = RemoteMountSpec(
            host: "cluster.internal",
            user: "dev",
            remotePath: "/srv/docs",
            targetKind: .folder
        )
        transport.seedFiles(for: spec.id, files: ["notes.md": "# Initial\n"])

        let manager = RemoteWorkspaceManager(
            transport: transport,
            mirrorBaseDirectory: tempMirror,
            userDefaults: defaults
        )
        manager.retryBackoffBaseSeconds = 60.0
        defer { manager.stopBackgroundSyncLoop() }

        let connected = await manager.addMount(spec)
        XCTAssertTrue(connected)

        let localNotesURL = manager.mirrorRootURL(for: spec).appendingPathComponent("notes.md")
        transport.pauseFirstPush()

        let firstSaveTask = Task {
            await manager.saveRemoteFile(at: localNotesURL, content: "# Revision 1\n")
        }
        await transport.waitUntilFirstPushEntersTransport()

        // Simulate a newer edit queued while Revision 1 is mid-upload, and fail the second push so it stays queued.
        transport.failSubsequentPushes = true
        await manager.saveRemoteFile(at: localNotesURL, content: "# Revision 2 (newer)\n")

        // Now let Revision 1 succeed: its completion must NOT wipe Revision 2 from pendingWriteQueue!
        transport.resumeFirstPush()
        await firstSaveTask.value

        XCTAssertEqual(
            manager.pendingWriteQueue.count,
            1,
            "Completing an older in-flight push must not dequeue a newer pending revision for the same file"
        )
        XCTAssertEqual(try String(contentsOf: localNotesURL, encoding: .utf8), "# Revision 2 (newer)\n")
        XCTAssertEqual(manager.syncStatus(forLocalURL: localNotesURL), .pendingUpload)

        // Once connectivity recovers, flushing uploads Revision 2 to the remote server.
        transport.failSubsequentPushes = false
        _ = await manager.syncMount(id: spec.id)
        XCTAssertTrue(manager.pendingWriteQueue.isEmpty)
        XCTAssertEqual(manager.syncStatus(forLocalURL: localNotesURL), .synced)
        XCTAssertEqual(transport.remoteFile(for: spec.id, relativePath: "notes.md"), "# Revision 2 (newer)\n")
    }
}

private final class GatedPushRemoteTransport: RemoteFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [UUID: [String: String]] = [:]
    private var stamps: [UUID: [String: TimeInterval]] = [:]
    private var nextStamp: TimeInterval = 1_800_000_000
    private var shouldPauseFirstPush = false
    private var hasPausedPush = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    var failSubsequentPushes = false

    func seedFiles(for mountID: UUID, files seeded: [String: String]) {
        lock.withLock {
            files[mountID] = seeded
            var mountStamps: [String: TimeInterval] = [:]
            for key in seeded.keys {
                nextStamp += 1
                mountStamps[key] = nextStamp
            }
            stamps[mountID] = mountStamps
        }
    }

    func remoteFile(for mountID: UUID, relativePath: String) -> String? {
        lock.withLock { files[mountID]?[relativePath] }
    }

    func pauseFirstPush() {
        lock.withLock {
            shouldPauseFirstPush = true
            hasPausedPush = false
        }
    }

    func waitUntilFirstPushEntersTransport() async {
        let alreadyPaused = lock.withLock { hasPausedPush }
        if alreadyPaused { return }
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if hasPausedPush {
                    return true
                }
                enteredContinuation = continuation
                return false
            }
            if immediate {
                continuation.resume()
            }
        }
    }

    func resumeFirstPush() {
        let cont = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            shouldPauseFirstPush = false
            let saved = resumeContinuation
            resumeContinuation = nil
            return saved
        }
        cont?.resume()
    }

    func listDirectories(
        _ relativePaths: [String],
        fileExtensions: Set<String>,
        for mount: RemoteMountSpec
    ) async throws -> [RemoteDirectoryListing] {
        let (mountFiles, mountStamps) = lock.withLock {
            (files[mount.id] ?? [:], stamps[mount.id] ?? [:])
        }
        return mockDirectoryListings(
            relativePaths,
            fileExtensions: fileExtensions,
            files: mountFiles,
            modificationTimestamps: mountStamps
        )
    }

    func probeDirectories(
        _ relativePaths: [String],
        fileExtensions: Set<String>,
        excludedPaths: Set<String>,
        for mount: RemoteMountSpec
    ) async throws -> [String: Bool] {
        let mountFiles = lock.withLock { files[mount.id] ?? [:] }
        return mockDirectoryProbes(
            relativePaths,
            fileExtensions: fileExtensions,
            excludedPaths: excludedPaths,
            files: mountFiles
        )
    }

    func fetchFiles(_ relativePaths: [String], for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
        let (mountFiles, mountStamps) = lock.withLock {
            (files[mount.id] ?? [:], stamps[mount.id] ?? [:])
        }
        return relativePaths.compactMap { path in
            mountFiles[path].map {
                RemoteFileEntry(relativePath: path, modificationTimestamp: mountStamps[path] ?? 0, content: $0)
            }
        }
    }

    func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
        let pauseThisCall = lock.withLock { () -> Bool in
            if shouldPauseFirstPush && !hasPausedPush {
                hasPausedPush = true
                return true
            }
            return false
        }

        if pauseThisCall {
            let entered = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let saved = enteredContinuation
                enteredContinuation = nil
                return saved
            }
            entered?.resume()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeImmediately = lock.withLock { () -> Bool in
                    if !shouldPauseFirstPush {
                        return true
                    }
                    resumeContinuation = continuation
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } else if lock.withLock({ failSubsequentPushes }) {
            throw RemoteWorkspaceError.transportTimeout(host: mount.host)
        }

        return lock.withLock {
            nextStamp += 1
            let stamp = nextStamp
            files[mount.id, default: [:]][relativePath] = content
            stamps[mount.id, default: [:]][relativePath] = stamp
            return stamp
        }
    }

    func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {
        lock.withLock {
            _ = files[mount.id]?.removeValue(forKey: relativePath)
            _ = stamps[mount.id]?.removeValue(forKey: relativePath)
        }
    }
}
