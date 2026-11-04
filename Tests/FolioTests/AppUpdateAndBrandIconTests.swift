import AppKit
import SwiftUI
import XCTest
@testable import Folio
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioTestSupport
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

final class AppUpdateAndBrandIconTests: XCTestCase {

    @MainActor
    func testAppUpdateManagerRollingAndVersionedComparisons() async throws {
        let installed = AppVersionInfo(
            shortVersion: "1.0.0",
            buildNumber: 12,
            commitSHA: "3f15af8",
            engineVersion: "0.1.0",
            repository: "lukeredmore/folio"
        )
        XCTAssertFalse(installed.isDevBuild)

        // 1. Same version and build number + matching SHA -> no update
        let sameBuild = ReleaseManifest(
            version: "1.0.0",
            buildNumber: 12,
            commitSHA: "3f15af8",
            engineVersion: "0.1.0",
            publishedAt: "2026-10-18T19:00:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: ""
        )
        XCTAssertFalse(AppUpdateManager.isUpdateAvailable(current: installed, remote: sameBuild))

        // 2. Rolling update WITHOUT marketing version change (1.0.0 build #12 -> 1.0.0 build #13)
        let rollingNewerBuild = ReleaseManifest(
            version: "1.0.0",
            buildNumber: 13,
            commitSHA: "a91bc02",
            engineVersion: "0.2.0",
            publishedAt: "2026-10-18T19:30:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: ""
        )
        XCTAssertTrue(AppUpdateManager.isUpdateAvailable(current: installed, remote: rollingNewerBuild))

        // 3. Semantic version bump (1.0.0 -> 1.1.0)
        let semverBump = ReleaseManifest(
            version: "1.1.0",
            buildNumber: 1,
            commitSHA: "b82cd11",
            engineVersion: "0.2.0",
            publishedAt: "2026-10-18T20:00:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: ""
        )
        XCTAssertTrue(AppUpdateManager.isUpdateAvailable(current: installed, remote: semverBump))

        // 4. Dev / debug builds (commitSHA == "dev" or isDevBuild == true) must never report an update available
        // or trigger automatic update checks on launch
        let devBuild = AppVersionInfo(
            shortVersion: "1.0.0",
            buildNumber: 1,
            commitSHA: "dev",
            engineVersion: "0.1.0",
            repository: "lukeredmore/folio"
        )
        XCTAssertTrue(devBuild.isDevBuild)
        XCTAssertFalse(AppUpdateManager.isUpdateAvailable(current: devBuild, remote: rollingNewerBuild))
        XCTAssertFalse(AppUpdateManager.isUpdateAvailable(current: devBuild, remote: semverBump))

        let devManager = AppUpdateManager(currentVersion: devBuild, userDefaults: isolatedDefaults())
        devManager.autoCheckForUpdates = true
        devManager.checkForUpdatesOnLaunchIfNeeded()
        await devManager.checkForUpdates(userInitiated: false)
        XCTAssertEqual(devManager.status, .idle)
        XCTAssertFalse(devManager.showUpdateSheet)

        // 5. Verify SHA-256 helper (must fail closed on empty or malformed digests)
        let tempFile = try makeTemporaryDirectory("folio-sha-test").appendingPathComponent("Folio.dmg")
        try Data("folio-dmg-payload".utf8).write(to: tempFile)
        // SHA-256("folio-dmg-payload") = cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e
        XCTAssertTrue(
            try AppUpdateManager.verifySHA256(
                fileURL: tempFile,
                expectedHex: "cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e"
            ))
        XCTAssertTrue(
            try AppUpdateManager.verifySHA256(
                fileURL: tempFile,
                expectedHex: "sha256:CD80BA81532451CEDACBBA4D7BD7E97A01150151BA665F29CDA50BD46018EA1E"
            ))
        XCTAssertFalse(
            try AppUpdateManager.verifySHA256(
                fileURL: tempFile,
                expectedHex: "0000000000000000000000000000000000000000000000000000000000000000"
            ))
        XCTAssertFalse(try AppUpdateManager.verifySHA256(fileURL: tempFile, expectedHex: ""))
        XCTAssertFalse(try AppUpdateManager.verifySHA256(fileURL: tempFile, expectedHex: "   \n"))
        XCTAssertFalse(try AppUpdateManager.verifySHA256(fileURL: tempFile, expectedHex: "cd80ba81"))
        XCTAssertFalse(
            try AppUpdateManager.verifySHA256(
                fileURL: tempFile,
                expectedHex: "zzzzba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e"
            ))

        // 6. Parse GitHub Releases REST API payload directly (no external JSON file needed)
        let ghReleasePayload = """
            {
              "tag_name": "latest",
              "name": "Folio v1.0.0 (Build #15 — 9f8e7d6)",
              "published_at": "2026-10-18T20:15:00Z",
              "body": "Automated rolling macOS build.\\n\\n<!-- folio-release: {\\"version\\":\\"1.0.0\\",\\"build_number\\":15,\\"commit_sha\\":\\"9f8e7d6\\",\\"engine_version\\":\\"0.1.0\\",\\"published_at\\":\\"2026-10-18T20:15:00Z\\",\\"dmg_url\\":\\"https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg\\",\\"dmg_sha256\\":\\"cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e\\",\\"notes\\":\\"feat: rolling update\\"} -->",
              "assets": [
                {
                  "name": "Folio.dmg",
                  "browser_download_url": "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
                  "digest": "sha256:cd80ba81532451cedacbba4d7bd7e97a01150151ba665f29cda50bd46018ea1e"
                }
              ]
            }
            """.data(using: .utf8)!

        let parsed = try ReleaseManifest.fromGitHubReleaseAPI(data: ghReleasePayload)
        XCTAssertEqual(parsed.version, "1.0.0")
        XCTAssertEqual(parsed.buildNumber, 15)
        XCTAssertEqual(parsed.commitSHA, "9f8e7d6")
        XCTAssertEqual(parsed.notes, "feat: rolling update")
        XCTAssertTrue(AppUpdateManager.isUpdateAvailable(current: installed, remote: parsed))
        XCTAssertFalse(AppUpdateManager.isUpdateAvailable(current: devBuild, remote: parsed))

        // 7. Prevent infinite update loop when a rolling release reuses an unchanged Folio.dmg
        // (e.g. installed app is Build #63 / 17694ec, release manifest says Build #64 / c8e075f,
        // but Folio.dmg has the same SHA-256 already installed for Build #63).
        let build63 = AppVersionInfo(
            shortVersion: "1.0.0",
            buildNumber: 63,
            commitSHA: "17694ec",
            engineVersion: "0.1.0",
            repository: "lukeredmore/folio"
        )
        let reusedDMGManifest = ReleaseManifest(
            version: "1.0.0",
            buildNumber: 64,
            commitSHA: "c8e075f",
            engineVersion: "0.1.0",
            publishedAt: "2026-10-23T23:13:56Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: "c76c4ef697078a1fb20a88b6eeda78d9941788422208581ca684ba690db49263"
        )
        let installedToken = AppVersionInfo.installedUpdateToken(for: build63, remote: reusedDMGManifest)
        XCTAssertFalse(
            AppUpdateManager.isUpdateAvailable(
                current: build63,
                remote: reusedDMGManifest,
                lastInstalledToken: installedToken
            )
        )
        // Once a genuinely new Folio.dmg with a different SHA-256 is published, update is offered again
        let newDMGManifest = ReleaseManifest(
            version: "1.0.0",
            buildNumber: 65,
            commitSHA: "f00baa1",
            engineVersion: "0.1.0",
            publishedAt: "2026-10-24T20:00:00Z",
            dmgURL: "https://github.com/lukeredmore/folio/releases/latest/download/Folio.dmg",
            dmgSHA256: "9999999999999999999999999999999999999999999999999999999999999999"
        )
        XCTAssertTrue(
            AppUpdateManager.isUpdateAvailable(
                current: build63,
                remote: newDMGManifest,
                lastInstalledToken: installedToken
            )
        )
    }

    func testDevBuildIconDetectionAndBannerRendering() throws {
        // 1. Stamped installed release build in /Applications should NOT use dev icon
        XCTAssertFalse(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/Applications/Folio.app",
                infoDictionary: [
                    "FolioBuildChannel": "release",
                    "FolioCommitSHA": "54b4d68"
                ],
                environment: [:]
            )
        )

        // 2. Legacy stamped installed build (no FolioBuildChannel, real commit SHA) should NOT use dev icon
        XCTAssertFalse(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/Applications/Folio.app",
                infoDictionary: [
                    "FolioCommitSHA": "54b4d68"
                ],
                environment: [:]
            )
        )

        // 3. Unstamped Bazel Info.plist (FolioBuildChannel=dev or FolioCommitSHA=dev) SHOULD use dev icon
        XCTAssertTrue(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/Applications/Folio.app",
                infoDictionary: [
                    "FolioBuildChannel": "dev",
                    "FolioCommitSHA": "dev"
                ],
                environment: [:]
            )
        )

        // 4. Bazel temporary unpacked bundle or bazel-out archive SHOULD use dev icon
        XCTAssertTrue(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/private/var/folders/xy/z/T/bazel_temp.abc123/Folio.app",
                infoDictionary: ["FolioBuildChannel": "release", "FolioCommitSHA": "54b4d68"],
                environment: [:]
            )
        )
        XCTAssertTrue(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath:
                    "/private/var/tmp/_bazel_user/hash/execroot/_main/bazel-out/darwin_arm64-fastbuild/bin/macos/FolioApp/FolioApp_archive-root/Folio.app",
                infoDictionary: ["FolioBuildChannel": "release", "FolioCommitSHA": "54b4d68"],
                environment: [:]
            )
        )

        // 5. Bazel runtime environment variables (bazel run) SHOULD use dev icon
        XCTAssertTrue(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/Applications/Folio.app",
                infoDictionary: ["FolioBuildChannel": "release", "FolioCommitSHA": "54b4d68"],
                environment: ["BUILD_WORKSPACE_DIRECTORY": "/Users/dev/Folio"]
            )
        )

        // 6. Explicit FOLIO_DEV_ICON override takes precedence
        XCTAssertTrue(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/Applications/Folio.app",
                infoDictionary: ["FolioBuildChannel": "release", "FolioCommitSHA": "54b4d68"],
                environment: ["FOLIO_DEV_ICON": "1"]
            )
        )
        XCTAssertFalse(
            FolioBrandIcon.isRunningDevBuild(
                bundlePath: "/private/var/folders/xy/z/T/bazel_temp.abc123/Folio.app",
                infoDictionary: ["FolioBuildChannel": "dev", "FolioCommitSHA": "dev"],
                environment: ["BUILD_WORKSPACE_DIRECTORY": "/Users/dev/Folio", "FOLIO_DEV_ICON": "0"]
            )
        )

        // 7. Verify DEV banner rendering alters lower-right badge pixels compared to release icon
        let releaseImage = FolioBrandIcon.makeAppIconImage(pixelSize: 128, isDark: false, isDevBuild: false)
        let devImage = FolioBrandIcon.makeAppIconImage(pixelSize: 128, isDark: false, isDevBuild: true)

        guard let releaseTIFF = releaseImage.tiffRepresentation,
            let devTIFF = devImage.tiffRepresentation,
            let releaseRep = NSBitmapImageRep(data: releaseTIFF),
            let devRep = NSBitmapImageRep(data: devTIFF)
        else {
            XCTFail("Expected bitmap representations for rendered app icons")
            return
        }

        // Top-left squircle area (outside the DEV badge) should match between release and dev icons
        XCTAssertEqual(releaseRep.colorAt(x: 40, y: 36), devRep.colorAt(x: 40, y: 36))

        // Lower-right badge region should differ markedly due to the orange/white DEV banner
        var differingBadgePixels = 0
        for y in 80..<106 {
            for x in 48..<104 {
                if releaseRep.colorAt(x: x, y: y) != devRep.colorAt(x: x, y: y) {
                    differingBadgePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(
            differingBadgePixels,
            500,
            "Expected DEV badge to render prominently in the lower-right region of the dev app icon"
        )
    }

    func testCodeSignatureVerificationEnforcesRequirementAndDetectsTampering() throws {
        XCTAssertEqual(
            AppUpdateManager.codeSigningRequirement(),
            #"identifier "app.folio.macos" and anchor apple generic and certificate leaf[subject.OU] = "XU8E27A586""#
        )

        let tempDir = try makeTemporaryDirectory("folio-codesign-test")
        let appURL = try makeSyntheticAppBundle(at: tempDir, bundleIdentifier: "app.folio.macos")

        // 1. Unsigned bundle must be rejected
        XCTAssertThrowsError(try AppUpdateManager.verifyCodeSignature(appBundleURL: appURL))

        // 2. Ad-hoc signed bundle must be rejected by the default pinned Apple+Team requirement
        try adHocSign(appBundleURL: appURL, identifier: "app.folio.macos")
        XCTAssertThrowsError(try AppUpdateManager.verifyCodeSignature(appBundleURL: appURL))

        // 3. Ad-hoc signed bundle with matching identifier satisfies an identifier-only requirement,
        //    and fails when checked against a mismatched identifier
        XCTAssertNoThrow(
            try AppUpdateManager.verifyCodeSignature(
                appBundleURL: appURL,
                requirement: #"identifier "app.folio.macos""#
            )
        )
        XCTAssertThrowsError(
            try AppUpdateManager.verifyCodeSignature(
                appBundleURL: appURL,
                requirement: #"identifier "com.example.untrusted""#
            )
        )

        // 4. Tampering with the signed executable after signing invalidates the signature
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Folio")
        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: executableURL)
        XCTAssertThrowsError(
            try AppUpdateManager.verifyCodeSignature(
                appBundleURL: appURL,
                requirement: #"identifier "app.folio.macos""#
            )
        )
    }

    private func makeSyntheticAppBundle(at parentDir: URL, bundleIdentifier: String) throws -> URL {
        let appURL = parentDir.appendingPathComponent("Folio.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macosURL, withIntermediateDirectories: true)

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "Folio",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Folio",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: infoPlistURL)

        let executableURL = macosURL.appendingPathComponent("Folio")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        return appURL
    }

    private func adHocSign(appBundleURL: URL, identifier: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = [
            "--force",
            "--deep",
            "--sign", "-",
            "--identifier", identifier,
            appBundleURL.path
        ]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
