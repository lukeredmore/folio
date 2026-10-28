import Foundation
import XCTest
@testable import Folio

/// Runs both `folio` launchers against fake dev and release apps, with fake `pgrep`, `ps`, `open`, and `osascript`.
@MainActor
final class CLILauncherBundleIsolationTests: XCTestCase {
    private struct Sandbox {
        let root: URL
        let home: URL
        let fakeBin: URL
        let workDir: URL
        let devApp: URL
        let releaseApp: URL

        var openArgsFile: URL { root.appendingPathComponent("open_args") }

        func queueFile(directoryName: String) -> URL {
            home.appendingPathComponent("Library/Application Support/\(directoryName)/cli_open_requests.txt")
        }
    }

    private static let bundledLauncherURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("macos/FolioApp/folio")

    private func launchers() throws -> [(name: String, url: URL)] {
        let generated = try makeTemporaryDirectory("folio-generated-cli").appendingPathComponent("folio-dev")
        let script = FolioCLIManager.generateCLIScript(
            fallbackAppBundlePath: "/nonexistent/Folio.app",
            bundleIdentifier: FolioAppIdentity.devBundleIdentifier
        )
        try Data(script.utf8).write(to: generated)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: generated.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Self.bundledLauncherURL.path), Self.bundledLauncherURL.path)
        return [("generated", generated), ("bundled", Self.bundledLauncherURL)]
    }

    private func makeSandbox() throws -> Sandbox {
        let root = try makeTemporaryDirectory("folio-cli-isolation")
        let sandbox = Sandbox(
            root: root,
            home: root.appendingPathComponent("home", isDirectory: true),
            fakeBin: root.appendingPathComponent("bin", isDirectory: true),
            workDir: root.appendingPathComponent("work", isDirectory: true),
            devApp: root.appendingPathComponent("dev/Folio.app", isDirectory: true),
            releaseApp: root.appendingPathComponent("release/Folio.app", isDirectory: true)
        )
        for dir in [sandbox.home, sandbox.fakeBin, sandbox.workDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try makeFakeApp(at: sandbox.devApp, bundleID: FolioAppIdentity.devBundleIdentifier)
        try makeFakeApp(at: sandbox.releaseApp, bundleID: FolioAppIdentity.releaseBundleIdentifier)
        let fakes = [
            "pgrep": "[[ \"$2\" == Folio ]] && cat \"$FAKE_DIR/pids\"\nexit 0",
            "ps": "awk -v pid=\"$2\" '$1 == pid { print $2 }' \"$FAKE_DIR/ps_map\"",
            "open": "printf '%s\\n' \"$@\" > \"$FAKE_DIR/open_args\"",
            "osascript": "exit 0"
        ]
        for (name, body) in fakes {
            let url = sandbox.fakeBin.appendingPathComponent(name)
            try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return sandbox
    }

    private func makeFakeApp(at app: URL, bundleID: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Folio"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// Starts a process that SIGUSR1 terminates, and lists it as the executable of `app` in the fake `ps`.
    private func startFakeFolio(for app: URL, in sandbox: Sandbox) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["30"]
        try proc.run()
        addTeardownBlock { if proc.isRunning { proc.terminate() } }
        let line = "\(proc.processIdentifier) \(app.path)/Contents/MacOS/Folio\n"
        let pidLine = "\(proc.processIdentifier)\n"
        try append(line, to: sandbox.root.appendingPathComponent("ps_map"))
        try append(pidLine, to: sandbox.root.appendingPathComponent("pids"))
        return proc
    }

    private func append(_ text: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try Data((existing + text).utf8).write(to: url)
    }

    private func run(_ launcher: URL, targeting app: URL, in sandbox: Sandbox) throws -> Int32 {
        let proc = Process()
        proc.executableURL = launcher
        proc.currentDirectoryURL = sandbox.workDir
        proc.arguments = ["notes.md:3"]
        proc.environment = [
            "PATH": "\(sandbox.fakeBin.path):/usr/bin:/bin",
            "HOME": sandbox.home.path,
            "FAKE_DIR": sandbox.root.path,
            "FOLIO_APP_PATH": app.path,
            "FOLIO_CALLER_CWD": sandbox.workDir.path
        ]
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func waitForExit(_ proc: Process) {
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testLauncherSignalsAndQueuesOnlyForItsOwnBundleID() throws {
        for (name, launcher) in try launchers() {
            let sandbox = try makeSandbox()
            let devProcess = try startFakeFolio(for: sandbox.devApp, in: sandbox)
            let releaseProcess = try startFakeFolio(for: sandbox.releaseApp, in: sandbox)

            XCTAssertEqual(try run(launcher, targeting: sandbox.devApp, in: sandbox), 0, name)
            waitForExit(devProcess)

            XCTAssertFalse(devProcess.isRunning, "\(name): the dev process gets SIGUSR1")
            XCTAssertEqual(devProcess.terminationReason, .uncaughtSignal, name)
            XCTAssertEqual(devProcess.terminationStatus, SIGUSR1, name)
            XCTAssertTrue(releaseProcess.isRunning, "\(name): the release process must not get SIGUSR1")
            let devQueue = try String(
                contentsOf: sandbox.queueFile(directoryName: "Folio-\(FolioAppIdentity.devBundleIdentifier)"),
                encoding: .utf8
            )
            XCTAssertTrue(devQueue.hasSuffix("/notes.md:3\n"), "\(name): \(devQueue)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.queueFile(directoryName: "Folio").path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.openArgsFile.path), "\(name): no new launch")
        }
    }

    func testReleaseLauncherOpensReleaseAppWhenOnlyDevIsRunning() throws {
        for (name, launcher) in try launchers() {
            let sandbox = try makeSandbox()
            let devProcess = try startFakeFolio(for: sandbox.devApp, in: sandbox)

            XCTAssertEqual(try run(launcher, targeting: sandbox.releaseApp, in: sandbox), 0, name)

            XCTAssertTrue(devProcess.isRunning, "\(name): a release open must not signal the dev process")
            let openArgs = try String(contentsOf: sandbox.openArgsFile, encoding: .utf8)
            XCTAssertTrue(openArgs.hasPrefix("-a\n\(sandbox.releaseApp.path)\n--args\n"), "\(name): \(openArgs)")
            let releaseQueue = try String(contentsOf: sandbox.queueFile(directoryName: "Folio"), encoding: .utf8)
            XCTAssertTrue(releaseQueue.hasSuffix("/notes.md:3\n"), "\(name): \(releaseQueue)")
        }
    }
}
