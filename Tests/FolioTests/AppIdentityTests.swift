import Foundation
import XCTest
@testable import Folio

@MainActor
final class AppIdentityTests: XCTestCase {
    private let release = FolioAppIdentity(bundleIdentifier: FolioAppIdentity.releaseBundleIdentifier)
    private let dev = FolioAppIdentity(bundleIdentifier: FolioAppIdentity.devBundleIdentifier)

    func testReleaseIdentityKeepsItsExistingStatePaths() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        let caches = URL(fileURLWithPath: "/Users/me/Library/Caches", isDirectory: true)
        let temp = URL(fileURLWithPath: "/private/var/folders/xy/T", isDirectory: true)

        XCTAssertTrue(release.isRelease)
        XCTAssertEqual(release.cliQueueFileURL(in: support).path, "/Users/me/Library/Application Support/Folio/cli_open_requests.txt")
        XCTAssertEqual(release.remoteMirrorRootURL(in: caches).path, "/Users/me/Library/Caches/FolioRemoteMirrors")
        XCTAssertEqual(release.remoteMediaDirectory(in: temp).path, "/private/var/folders/xy/T/folio-remote-media")
        XCTAssertEqual(release.sshControlSocketPath(hash: "abc123"), "/tmp/folio-ssh-abc123.sock")
        XCTAssertEqual(release.cliCommandName, "folio")
        XCTAssertEqual(release.signpostSubsystem, "app.folio.macos")
    }

    func testOtherBundleIDsDeriveTheirOwnStatePaths() {
        let support = URL(fileURLWithPath: "/Users/me/Library/Application Support", isDirectory: true)
        let caches = URL(fileURLWithPath: "/Users/me/Library/Caches", isDirectory: true)
        let temp = URL(fileURLWithPath: "/private/var/folders/xy/T", isDirectory: true)

        XCTAssertFalse(dev.isRelease)
        XCTAssertEqual(dev.bundleIdentifier, "app.folio.macos.dev")
        XCTAssertEqual(
            dev.cliQueueFileURL(in: support).path,
            "/Users/me/Library/Application Support/Folio-app.folio.macos.dev/cli_open_requests.txt"
        )
        XCTAssertEqual(dev.remoteMirrorRootURL(in: caches).path, "/Users/me/Library/Caches/FolioRemoteMirrors-app.folio.macos.dev")
        XCTAssertEqual(dev.remoteMediaDirectory(in: temp).path, "/private/var/folders/xy/T/folio-remote-media-app.folio.macos.dev")
        XCTAssertEqual(dev.sshControlSocketPath(hash: "abc123"), "/tmp/folio-ssh-app.folio.macos.dev-abc123.sock")
        XCTAssertEqual(dev.cliCommandName, "folio-dev")
        XCTAssertEqual(dev.signpostSubsystem, "app.folio.macos.dev")

        let other = FolioAppIdentity(bundleIdentifier: "com.example.fork")
        XCTAssertFalse(other.isRelease)
        XCTAssertEqual(other.cliQueueFileURL(in: support).deletingLastPathComponent().lastPathComponent, "Folio-com.example.fork")

        XCTAssertEqual(FolioAppIdentity(bundleIdentifier: nil), dev, "An unbundled process must not use release state")
        XCTAssertEqual(FolioAppIdentity(bundleIdentifier: "  "), dev)
    }

    func testCurrentIdentityAndDefaultPathsComeFromTheMainBundleID() {
        let current = FolioAppIdentity.current
        XCTAssertEqual(current, FolioAppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier))
        XCTAssertFalse(current.isRelease, "Tests must never run with the release identity")
        XCTAssertTrue(
            FolioCLIManager.defaultQueueFileURL.path.contains("/Folio-\(current.bundleIdentifier)/"),
            FolioCLIManager.defaultQueueFileURL.path
        )
        XCTAssertTrue(
            SSHRemoteTransport().controlSocketPath(for: RemoteMountSpec(host: "example.com", remotePath: "/srv"))
                .hasPrefix("/tmp/folio-ssh-\(current.bundleIdentifier)-")
        )
    }

    func testDevBuildsNeverInstallTheReleaseLauncher() throws {
        let binDir = try makeTemporaryDirectory("folio-dev-cli")
        let skipped = FolioCLIManager.shared.setupCLIOnFirstLaunchIfNeeded(
            candidateBinDirs: [binDir],
            appBundleURL: URL(fileURLWithPath: "/tmp/dev/Folio.app"),
            userDefaults: isolatedDefaults(),
            identity: dev
        )
        XCTAssertNil(skipped, "Dev builds must not install a launcher on launch")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: binDir.path), [])

        let installed = FolioCLIManager.shared.installCLI(
            into: [binDir],
            appBundleURL: URL(fileURLWithPath: "/tmp/dev/Folio.app"),
            userDefaults: isolatedDefaults(),
            identity: dev
        )
        XCTAssertEqual(installed?.lastPathComponent, "folio-dev")
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDir.appendingPathComponent("folio").path))
        let script = try String(contentsOf: try XCTUnwrap(installed), encoding: .utf8)
        XCTAssertTrue(script.contains("EXPECTED_BUNDLE_ID=\"app.folio.macos.dev\""))
        XCTAssertTrue(script.contains(FolioCLIManager.cliScriptMarker))
    }

    func testNonReleaseBundleIDIsADevBuildThatNeverInstallsUpdates() async {
        let releaseInfo: [String: Any] = [
            "CFBundleIdentifier": "app.folio.macos",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "40",
            "FolioBuildChannel": "release",
            "FolioCommitSHA": "3f15af8"
        ]
        var devInfo = releaseInfo
        devInfo["CFBundleIdentifier"] = "app.folio.macos.dev"
        let installed = "/Applications/Folio.app"
        XCTAssertFalse(AppVersionInfo.fromInfoDictionary(releaseInfo, bundlePath: installed, environment: [:]).isDevBuild)
        let devVersion = AppVersionInfo.fromInfoDictionary(devInfo, bundlePath: installed, environment: [:])
        XCTAssertTrue(devVersion.isDevBuild)

        let manager = AppUpdateManager(currentVersion: devVersion, userDefaults: isolatedDefaults())
        // An empty URL keeps the test offline even if the dev guard is missing.
        let manifest = ReleaseManifest(
            version: "9.9.9",
            buildNumber: 999,
            commitSHA: "a91bc02",
            engineVersion: "0.2.0",
            publishedAt: "2026-10-18T19:30:00Z",
            dmgURL: "",
            dmgSHA256: ""
        )
        XCTAssertFalse(AppUpdateManager.isUpdateAvailable(current: devVersion, remote: manifest))
        await manager.downloadAndInstallUpdate(manifest)
        XCTAssertEqual(manager.status, .error("Dev builds do not install updates."))
    }
}
