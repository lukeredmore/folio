import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import Folio

@MainActor
final class CLILauncherAndBazelRunTests: XCTestCase {

    func testEvaluateImmediateCLIActionForHelpAndVersion() {
        let helpShort = FolioCLIManager.evaluateImmediateCLIAction(
            arguments: ["/path/to/FolioApp", "-h"]
        )
        XCTAssertEqual(helpShort, .printHelp(FolioCLIManager.helpText))

        let helpLong = FolioCLIManager.evaluateImmediateCLIAction(
            arguments: ["/path/to/FolioApp", "--help"]
        )
        XCTAssertEqual(helpLong, .printHelp(FolioCLIManager.helpText))

        let versionAction = FolioCLIManager.evaluateImmediateCLIAction(
            arguments: ["/path/to/FolioApp", "--version"],
            bundleInfoDictionary: ["CFBundleShortVersionString": "2.4.1"]
        )
        XCTAssertEqual(versionAction, .printVersion("folio 2.4.1"))

        // Flags after `--` are treated as file paths, not immediate CLI actions
        let dashDashHelp = FolioCLIManager.evaluateImmediateCLIAction(
            arguments: ["/path/to/FolioApp", "--", "--help"]
        )
        XCTAssertNil(dashDashHelp)
    }

    func testEffectiveWorkingDirectoryHonorsBazelAndCallerEnvironment() {
        XCTAssertEqual(
            FolioCLIManager.effectiveWorkingDirectoryPath(
                environment: [:],
                currentDirectoryPath: "/private/tmp/runfiles"
            ),
            "/private/tmp/runfiles"
        )

        XCTAssertEqual(
            FolioCLIManager.effectiveWorkingDirectoryPath(
                environment: ["BUILD_WORKING_DIRECTORY": "/Users/dev/project"],
                currentDirectoryPath: "/private/tmp/runfiles"
            ),
            "/Users/dev/project"
        )

        XCTAssertEqual(
            FolioCLIManager.effectiveWorkingDirectoryPath(
                environment: [
                    "FOLIO_CALLER_CWD": "/Users/dev/override",
                    "BUILD_WORKING_DIRECTORY": "/Users/dev/project"
                ],
                currentDirectoryPath: "/private/tmp/runfiles"
            ),
            "/Users/dev/override"
        )
    }

    func testExtractCommandLinePathsSupportsLineColumnTildeFileURLAndDashDash() {
        let args = [
            "/Applications/Folio.app/Contents/MacOS/FolioApp",
            "-NSDocumentRevisionsDebugMode", "YES",
            "--foreground",
            "-n",
            ".",
            "docs/guide.md:24:5",
            "file:///tmp/spec.md:9",
            "--",
            "-leading-dash.md:3"
        ]
        let extracted = FolioCLIManager.extractCommandLinePaths(
            from: args,
            currentDirectoryPath: "/Users/dev/repo"
        )
        XCTAssertEqual(
            extracted,
            [
                "/Users/dev/repo",
                "/Users/dev/repo/docs/guide.md:24:5",
                "/tmp/spec.md:9",
                "/Users/dev/repo/-leading-dash.md:3"
            ]
        )
    }

    func testCLIOpenUpdatesMountedTextViewAndNavigatesToLineAndColumn() throws {
        let tempDir = try makeTemporaryDirectory("folio-cli-line-nav")

        let docURL = tempDir.appendingPathComponent("sample.md")
        let content = "# Heading\nSecond line text\nThird line target here\nFourth line\n"
        try content.write(to: docURL, atomically: true, encoding: .utf8)

        let vm = makeIsolatedViewModel()
        let hostingView = NSHostingView(rootView: MainWindowView(viewModel: vm))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))

        XCTAssertNotNil(vm.activeTextView)

        // Open sample.md at line 3, column 7 ("target") while activeTextView is already mounted
        vm.openPathFromCLI("\(docURL.path):3:7")

        XCTAssertEqual(vm.currentFileURL?.standardizedFileURL, docURL.standardizedFileURL)
        XCTAssertEqual(vm.markdownText, content)
        XCTAssertEqual(vm.activeTextView?.string, content)

        // Line 1 ("# Heading\n") = 10 chars, Line 2 ("Second line text\n") = 17 chars, Col 7 = +6 chars -> offset 33
        XCTAssertEqual(vm.currentSelectedRange, NSRange(location: 33, length: 0))
        XCTAssertEqual(vm.activeTextView?.selectedRange(), NSRange(location: 33, length: 0))
    }

    func testCLIScriptSymlinkResolutionAndLineSuffixWithoutBogusFileTouch() throws {
        let tempRoot = try makeTemporaryDirectory("folio-cli-symlink")
        let fakeAppMacOS = tempRoot
            .appendingPathComponent("Folio.app/Contents/MacOS", isDirectory: true)
        let fakeAppBin = tempRoot
            .appendingPathComponent("Folio.app/Contents/Resources/bin", isDirectory: true)
        let fakeAppResources = tempRoot
            .appendingPathComponent("Folio.app/Contents", isDirectory: true)
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        let workDir = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let queueFile = tempRoot.appendingPathComponent("queue/cli_open_requests.txt")

        try FileManager.default.createDirectory(at: fakeAppMacOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeAppBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Create a mock Folio executable inside Folio.app/Contents/MacOS/Folio for --foreground
        let mockFolioAppBin = fakeAppMacOS.appendingPathComponent("Folio")
        let mockAppScript = """
        #!/usr/bin/env bash
        printf 'CWD=%s\\n' "${FOLIO_CALLER_CWD:-}"
        for a in "$@"; do
            printf 'ARG=%s\\n' "$a"
        done
        """
        try Data(mockAppScript.utf8).write(to: mockFolioAppBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockFolioAppBin.path)

        let infoPlist = fakeAppResources.appendingPathComponent("Info.plist")
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>3.2.0</string>
        </dict>
        </plist>
        """
        try Data(plistContent.utf8).write(to: infoPlist)

        // Write the bundled CLI script into Folio.app/Contents/Resources/bin/folio and symlink bin/folio -> ../Folio.app/Contents/Resources/bin/folio
        let bundledCLI = FolioCLIManager.bundledCLILauncherURL(in: tempRoot.appendingPathComponent("Folio.app"))
        let cliContent = FolioCLIManager.generateCLIScript(
            fallbackAppBundlePath: "/nonexistent/Folio.app",
            queueFilePath: queueFile.path
        )
        try Data(cliContent.utf8).write(to: bundledCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLI.path)

        let symlinkCLI = binDir.appendingPathComponent("folio")
        try FileManager.default.createSymbolicLink(
            atPath: symlinkCLI.path,
            withDestinationPath: "../Folio.app/Contents/Resources/bin/folio"
        )

        // Invoking via the relative symlink with `--foreground new_doc.md:15:2` should:
        // 1. Resolve Folio.app via the symlink chain
        // 2. Create `new_doc.md` (and NOT `new_doc.md:15:2`)
        // 3. Pass `/.../workspace/new_doc.md:15:2` to FolioApp
        let proc = Process()
        proc.executableURL = symlinkCLI
        proc.currentDirectoryURL = workDir
        proc.arguments = ["--foreground", "new_doc.md:15:2"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        try proc.run()
        proc.waitUntilExit()

        XCTAssertEqual(proc.terminationStatus, 0)
        let stdoutStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let resolvedWorkDir: String
        if let realPtr = realpath(workDir.path, nil) {
            resolvedWorkDir = String(cString: realPtr)
            free(realPtr)
        } else {
            resolvedWorkDir = workDir.resolvingSymlinksInPath().path
        }
        XCTAssertTrue(stdoutStr.contains("CWD=\(resolvedWorkDir)"), "stdout was: \(stdoutStr)")
        XCTAssertTrue(stdoutStr.contains("ARG=\(resolvedWorkDir)/new_doc.md:15:2"), "stdout was: \(stdoutStr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("new_doc.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent("new_doc.md:15:2").path))
    }
}
