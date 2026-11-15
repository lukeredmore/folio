import AppKit
import Foundation
import XCTest
@testable import Folio
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioTestSupport
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

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

    /// Starts a fake Folio process that ignores `SIGUSR1` (just like the real `FolioCLIManager` signal source).
    private func startPersistentFakeFolio(for app: URL, in sandbox: Sandbox) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "trap '' USR1\nsleep 30"]
        try proc.run()
        addTeardownBlock { if proc.isRunning { proc.terminate() } }
        let line = "\(proc.processIdentifier) \(app.path)/Contents/MacOS/Folio\n"
        let pidLine = "\(proc.processIdentifier)\n"
        try append(line, to: sandbox.root.appendingPathComponent("ps_map"))
        try append(pidLine, to: sandbox.root.appendingPathComponent("pids"))
        return proc
    }

    private func removeFakeFolioFromProcessTable(_ proc: Process, in sandbox: Sandbox) throws {
        if proc.isRunning { proc.terminate() }
        waitForExit(proc)
        let pidString = "\(proc.processIdentifier)"
        let pidsURL = sandbox.root.appendingPathComponent("pids")
        if let existing = try? String(contentsOf: pidsURL, encoding: .utf8) {
            let filtered =
                existing
                .components(separatedBy: .newlines)
                .filter { !$0.isEmpty && $0 != pidString }
                .joined(separator: "\n")
            try Data((filtered.isEmpty ? "" : filtered + "\n").utf8).write(to: pidsURL)
        }
    }

    private func startAsyncLauncher(
        _ launcher: URL,
        arguments: [String],
        targeting app: URL?,
        in sandbox: Sandbox
    ) throws -> (process: Process, stdout: Pipe, stderr: Pipe) {
        let proc = Process()
        proc.executableURL = launcher
        proc.currentDirectoryURL = sandbox.workDir
        proc.arguments = arguments
        var env = [
            "PATH": "\(sandbox.fakeBin.path):/usr/bin:/bin",
            "HOME": sandbox.home.path,
            "FAKE_DIR": sandbox.root.path,
            "FOLIO_CALLER_CWD": sandbox.workDir.path
        ]
        if let app {
            env["FOLIO_APP_PATH"] = app.path
        }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        addTeardownBlock { if proc.isRunning { proc.terminate() } }
        return (proc, outPipe, errPipe)
    }

    private func waitForQueueRequests(at queueURL: URL) -> [FolioCLIOpenRequest] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let items = FolioCLIManager.drainPendingOpenRequestItems(from: queueURL)
            if !items.isEmpty {
                return items
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return []
    }

    func testBothLaunchersShareCanonicalSourceMatchHelpVersionAndRejectUnknownFlags() throws {
        let bundledSource = try String(contentsOf: Self.bundledLauncherURL, encoding: .utf8)
        XCTAssertEqual(FolioCLIManager.canonicalCLILauncherScript, bundledSource)

        let sandbox = try makeSandbox()
        let versionedPlist: [String: Any] = [
            "CFBundleIdentifier": FolioAppIdentity.devBundleIdentifier,
            "CFBundleExecutable": "Folio",
            "CFBundleShortVersionString": "4.2.7"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: versionedPlist, format: .xml, options: 0)
        try plistData.write(to: sandbox.devApp.appendingPathComponent("Contents/Info.plist"))

        for (name, launcher) in try launchers() {
            let helpRun = try startAsyncLauncher(launcher, arguments: ["--help"], targeting: sandbox.devApp, in: sandbox)
            helpRun.process.waitUntilExit()
            let helpOut = String(data: helpRun.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(helpRun.process.terminationStatus, 0, name)
            XCTAssertEqual(helpOut, FolioCLIManager.helpText + "\n", name)

            let versionRun = try startAsyncLauncher(launcher, arguments: ["--version"], targeting: sandbox.devApp, in: sandbox)
            versionRun.process.waitUntilExit()
            let versionOut = String(data: versionRun.stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(versionRun.process.terminationStatus, 0, name)
            XCTAssertEqual(versionOut, "folio 4.2.7\n", name)

            let untouchedFile = sandbox.workDir.appendingPathComponent("must_not_exist_\(name).md")
            let bogusRun = try startAsyncLauncher(
                launcher,
                arguments: ["--bogus-flag", untouchedFile.lastPathComponent],
                targeting: sandbox.devApp,
                in: sandbox
            )
            bogusRun.process.waitUntilExit()
            let bogusErr = String(data: bogusRun.stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTAssertEqual(bogusRun.process.terminationStatus, 2, name)
            XCTAssertTrue(bogusErr.contains("unknown option: --bogus-flag"), "\(name): \(bogusErr)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: untouchedFile.path), name)
        }

        // Missing app bundle also exits before touching nonexistent target files
        let missingLauncher = sandbox.root.appendingPathComponent("folio-missing")
        let missingScript = FolioCLIManager.generateCLIScript(
            fallbackAppBundlePath: "/nonexistent/Folio.app",
            bundleIdentifier: "app.folio.macos.nonexistent-test"
        )
        try Data(missingScript.utf8).write(to: missingLauncher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: missingLauncher.path)
        let fakeMdfind = sandbox.fakeBin.appendingPathComponent("mdfind")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: fakeMdfind)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeMdfind.path)

        let missingTarget = sandbox.workDir.appendingPathComponent("never_touched.md")
        let missingRun = try startAsyncLauncher(
            missingLauncher,
            arguments: [missingTarget.lastPathComponent],
            targeting: nil,
            in: sandbox
        )
        missingRun.process.waitUntilExit()
        XCTAssertEqual(missingRun.process.terminationStatus, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testLauncherWaitBlocksAndFlushesUnsavedEditsBeforeUnblockingOnCloseAndTerminate() throws {
        for (name, launcher) in try launchers() {
            let sandbox = try makeSandbox()
            _ = try startPersistentFakeFolio(for: sandbox.devApp, in: sandbox)
            let queueURL = sandbox.queueFile(directoryName: "Folio-\(FolioAppIdentity.devBundleIdentifier)")

            let defaults = isolatedDefaults()
            let mirrorDir = sandbox.root.appendingPathComponent("mirror", isDirectory: true)
            try FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
            let registry = DocumentWindowRegistry(
                userDefaults: defaults,
                remoteWorkspaceManager: RemoteWorkspaceManager(mirrorBaseDirectory: mirrorDir, userDefaults: defaults)
            )
            let initialVM = registry.makeViewModel(for: DocumentWindowValue())
            XCTAssertTrue(registry.claimLaunchSetup(for: initialVM))

            // 1. Window close (`Cmd+W`) flushes pending debounced edits to disk BEFORE `folio --wait` exits 0
            let commitFile = sandbox.workDir.appendingPathComponent("COMMIT_EDITMSG")
            try "".write(to: commitFile, atomically: true, encoding: .utf8)

            let closeWaitRun = try startAsyncLauncher(
                launcher,
                arguments: ["--wait", "COMMIT_EDITMSG"],
                targeting: sandbox.devApp,
                in: sandbox
            )
            let closeRequests = waitForQueueRequests(at: queueURL)
            XCTAssertEqual(closeRequests.count, 1, name)
            let closeTokenPath = try XCTUnwrap(closeRequests.first?.waitTokenPath, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: closeTokenPath), name)

            registry.openRequests(closeRequests)
            let waitedVM = try XCTUnwrap(registry.activeViewModel, name)
            waitedVM.autoSaveDelay = 60
            waitedVM.handleEditorTextEdited("Implement blocking --wait\n", selectedRange: NSRange(location: 26, length: 0))
            XCTAssertTrue(waitedVM.isDirty, name)
            XCTAssertTrue(waitedVM.hasPendingAutoSave, name)
            XCTAssertEqual(try String(contentsOf: commitFile, encoding: .utf8), "", name)

            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            XCTAssertTrue(closeWaitRun.process.isRunning, "\(name): folio --wait must remain blocked while document is open")

            registry.closeWindow(for: waitedVM)
            waitForExit(closeWaitRun.process)

            XCTAssertFalse(closeWaitRun.process.isRunning, name)
            XCTAssertEqual(closeWaitRun.process.terminationStatus, 0, name)
            XCTAssertEqual(try String(contentsOf: commitFile, encoding: .utf8), "Implement blocking --wait\n", name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: closeTokenPath), name)

            // 2. App termination (`Cmd+Q` / `applicationShouldTerminate`) also flushes pending edits before unblocking
            let quitDefaults = isolatedDefaults()
            let quitRegistry = DocumentWindowRegistry(
                userDefaults: quitDefaults,
                remoteWorkspaceManager: RemoteWorkspaceManager(mirrorBaseDirectory: mirrorDir, userDefaults: quitDefaults)
            )
            let quitWindowVM = quitRegistry.makeViewModel(for: DocumentWindowValue())
            XCTAssertTrue(quitRegistry.claimLaunchSetup(for: quitWindowVM))
            let quitFile = sandbox.workDir.appendingPathComponent("QUIT_COMMIT_MSG")
            try "".write(to: quitFile, atomically: true, encoding: .utf8)

            let quitWaitRun = try startAsyncLauncher(
                launcher,
                arguments: ["-w", "QUIT_COMMIT_MSG"],
                targeting: sandbox.devApp,
                in: sandbox
            )
            let quitRequests = waitForQueueRequests(at: queueURL)
            XCTAssertEqual(quitRequests.count, 1, name)
            quitRegistry.openRequests(quitRequests)
            XCTAssertEqual(quitRegistry.activeWaitTokenPaths.count, 1, name)

            let activeQuitVM = try XCTUnwrap(quitRegistry.activeViewModel, name)
            activeQuitVM.autoSaveDelay = 60
            activeQuitVM.handleEditorTextEdited("Saved before Cmd+Q\n", selectedRange: NSRange(location: 19, length: 0))
            XCTAssertTrue(activeQuitVM.isDirty, name)
            XCTAssertEqual(try String(contentsOf: quitFile, encoding: .utf8), "", name)
            XCTAssertTrue(quitWaitRun.process.isRunning, name)

            let appDelegate = FolioAppDelegate()
            appDelegate.registry = quitRegistry
            XCTAssertEqual(appDelegate.applicationShouldTerminate(NSApplication.shared), .terminateNow, name)
            waitForExit(quitWaitRun.process)

            XCTAssertFalse(quitWaitRun.process.isRunning, name)
            XCTAssertEqual(quitWaitRun.process.terminationStatus, 0, name)
            XCTAssertEqual(try String(contentsOf: quitFile, encoding: .utf8), "Saved before Cmd+Q\n", name)
            XCTAssertTrue(quitRegistry.activeWaitTokenPaths.isEmpty, name)
        }
    }

    func testLauncherWaitUnblocksCleanlyWhenTargetFolioProcessExitsUnexpectedly() throws {
        for (name, launcher) in try launchers() {
            let sandbox = try makeSandbox()
            let fakeFolio = try startPersistentFakeFolio(for: sandbox.devApp, in: sandbox)
            let queueURL = sandbox.queueFile(directoryName: "Folio-\(FolioAppIdentity.devBundleIdentifier)")

            let waitRun = try startAsyncLauncher(
                launcher,
                arguments: ["--wait", "crashed.md"],
                targeting: sandbox.devApp,
                in: sandbox
            )
            let requests = waitForQueueRequests(at: queueURL)
            let tokenPath = try XCTUnwrap(requests.first?.waitTokenPath, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tokenPath), name)

            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            XCTAssertTrue(waitRun.process.isRunning, name)

            // Simulate Folio crashing/exiting without unlinking `tokenPath`
            try removeFakeFolioFromProcessTable(fakeFolio, in: sandbox)
            waitForExit(waitRun.process)

            XCTAssertFalse(waitRun.process.isRunning, "\(name): folio --wait must unblock when Folio exits")
            XCTAssertEqual(waitRun.process.terminationStatus, 0, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tokenPath), "\(name): trap cleans up wait sentinel")
        }
    }

    func testLauncherWaitWithNoPathsPassesOpenWaitFlagOrWaitsForRunningInstance() throws {
        for (name, launcher) in try launchers() {
            // 1. No running instance -> passes `-W` to `open`
            let coldSandbox = try makeSandbox()
            let coldRun = try startAsyncLauncher(
                launcher,
                arguments: ["--wait"],
                targeting: coldSandbox.releaseApp,
                in: coldSandbox
            )
            coldRun.process.waitUntilExit()
            XCTAssertEqual(coldRun.process.terminationStatus, 0, name)
            let openArgs = try String(contentsOf: coldSandbox.openArgsFile, encoding: .utf8)
            XCTAssertEqual(openArgs, "-W\n-a\n\(coldSandbox.releaseApp.path)\n", name)

            // 2. Running instance -> activates and blocks until the running instance exits
            let warmSandbox = try makeSandbox()
            let runningFolio = try startPersistentFakeFolio(for: warmSandbox.devApp, in: warmSandbox)
            let warmRun = try startAsyncLauncher(
                launcher,
                arguments: ["-w"],
                targeting: warmSandbox.devApp,
                in: warmSandbox
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertTrue(warmRun.process.isRunning, "\(name): folio -w blocks while Folio is running")
            XCTAssertFalse(FileManager.default.fileExists(atPath: warmSandbox.openArgsFile.path), name)

            try removeFakeFolioFromProcessTable(runningFolio, in: warmSandbox)
            waitForExit(warmRun.process)
            XCTAssertFalse(warmRun.process.isRunning, name)
            XCTAssertEqual(warmRun.process.terminationStatus, 0, name)
        }
    }
}
