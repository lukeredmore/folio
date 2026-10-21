import Foundation
import XCTest
@testable import Folio

final class RemoteImageSSHAuthTests: XCTestCase {

    override func tearDown() {
        FolioMediaImageCache.shared.curlCommandPrefix = FolioMediaImageCache.defaultCurlCommandPrefix
        FolioMediaImageCache.shared.sshAuthConfig = .disabled
        FolioMediaImageCache.shared.clearRemoteCache()
        super.tearDown()
    }

    func testResolveSSHFamilyRemoteURLsAndBuildCurlFlagsFromRemoteMount() throws {
        let sftpURL = try XCTUnwrap(
            FolioMediaImageCache.resolveRemoteURL(from: "sftp://files.example.com/var/media/architecture.png")
        )
        let scpURL = try XCTUnwrap(
            FolioMediaImageCache.resolveRemoteURL(from: "scp://alice@devbox.internal/~/diagrams/flow.svg")
        )
        let sshURL = try XCTUnwrap(
            FolioMediaImageCache.resolveRemoteURL(from: "ssh://devbox.internal:2222/var/img.png")
        )
        XCTAssertTrue(FolioMediaImageCache.isSSHFamilyURL(sftpURL))
        XCTAssertTrue(FolioMediaImageCache.isSSHFamilyURL(scpURL))
        XCTAssertTrue(FolioMediaImageCache.isSSHFamilyURL(sshURL))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-ssh-key-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyFile = tempDir.appendingPathComponent("id_ed25519")
        let pubFile = tempDir.appendingPathComponent("id_ed25519.pub")
        try "PRIVATE_KEY".write(to: keyFile, atomically: true, encoding: .utf8)
        try "PUBLIC_KEY".write(to: pubFile, atomically: true, encoding: .utf8)

        let mount = RemoteMountSpec(
            host: "files.example.com",
            user: "deploy",
            port: 2222,
            remotePath: "/var/media",
            targetKind: .folder,
            identityFile: keyFile.path
        )

        let sshConfig = FolioMediaSSHAuthConfig(
            isEnabled: true,
            identityFile: nil,
            user: nil,
            mounts: [mount]
        )

        let cmd = FolioMediaImageCache.buildCurlShellCommand(
            for: sftpURL,
            commandPrefix: "curl",
            sshAuth: sshConfig
        )
        XCTAssertEqual(
            cmd,
            "curl -u 'deploy:' --key '\(keyFile.path)' --pubkey '\(pubFile.path)' -sS -L --fail --max-time 30 'sftp://files.example.com/var/media/architecture.png'"
        )

        // URL with its own username ("alice") should prefer the URL username while still using the mount's SSH key
        let scpCmd = FolioMediaImageCache.buildCurlShellCommand(
            for: scpURL,
            commandPrefix: "curl",
            sshAuth: sshConfig
        )
        XCTAssertEqual(
            scpCmd,
            "curl -u 'alice:' --key '\(keyFile.path)' --pubkey '\(pubFile.path)' -sS -L --fail --max-time 30 'scp://alice@devbox.internal/~/diagrams/flow.svg'"
        )

        // When curlCommandPrefix already contains -u or --key, do not duplicate them
        let manualPrefixCmd = FolioMediaImageCache.buildCurlShellCommand(
            for: sftpURL,
            commandPrefix: "curl -u custom: --key /custom/key",
            sshAuth: sshConfig
        )
        XCTAssertEqual(
            manualPrefixCmd,
            "curl -u custom: --key /custom/key -sS -L --fail --max-time 30 'sftp://files.example.com/var/media/architecture.png'"
        )
    }

    @MainActor
    func testViewModelSSHAuthSyncAndPersistence() throws {
        let suiteName = "FolioTests.RemoteImageSSHAuth.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mount = RemoteMountSpec(
            host: "corp-media.example.com",
            user: "luke",
            port: 22,
            remotePath: "~/notes",
            targetKind: .folder,
            identityFile: "/tmp/test_id_ed25519"
        )
        let manager = RemoteWorkspaceManager(
            userDefaults: defaults,
            mountsDefaultsKey: "FolioTests.Mounts.\(UUID().uuidString)"
        )
        manager.mounts = [mount]

        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: manager, userDefaults: defaults)
        XCTAssertFalse(vm.useSSHAuthForMedia)
        XCTAssertFalse(FolioMediaImageCache.shared.sshAuthConfig.isEnabled)

        vm.applySSHAuthFromMount(mount)
        XCTAssertTrue(vm.useSSHAuthForMedia)
        XCTAssertEqual(vm.mediaSSHUser, "luke")
        XCTAssertEqual(vm.mediaSSHIdentityFile, "/tmp/test_id_ed25519")
        XCTAssertTrue(FolioMediaImageCache.shared.sshAuthConfig.isEnabled)
        XCTAssertEqual(FolioMediaImageCache.shared.sshAuthConfig.user, "luke")
        XCTAssertEqual(FolioMediaImageCache.shared.sshAuthConfig.identityFile, "/tmp/test_id_ed25519")

        // Verify persistence across ViewModel re-initialization
        let restoredVM = EditorWorkspaceViewModel(remoteWorkspaceManager: manager, userDefaults: defaults)
        XCTAssertTrue(restoredVM.useSSHAuthForMedia)
        XCTAssertEqual(restoredVM.mediaSSHUser, "luke")
        XCTAssertEqual(restoredVM.mediaSSHIdentityFile, "/tmp/test_id_ed25519")

        restoredVM.resetMediaCurlCommandPrefixToDefault()
        XCTAssertFalse(restoredVM.useSSHAuthForMedia)
        XCTAssertEqual(restoredVM.mediaSSHUser, "")
        XCTAssertEqual(restoredVM.mediaSSHIdentityFile, "")
        XCTAssertFalse(FolioMediaImageCache.shared.sshAuthConfig.isEnabled)
    }
}
