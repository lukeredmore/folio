import AppKit
import XCTest
@testable import Folio

@MainActor
final class AutosaveDebounceTests: XCTestCase {

    /// Transport that records every pushed content, in order, and takes a little time per push.
    private final class RecordingTransport: RemoteFileTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: String] = [:]
        private var pushes: [String] = []
        private var concurrent = 0
        private(set) var maxConcurrent = 0

        func seed(_ relativePath: String, _ content: String) { lock.withLock { files[relativePath] = content } }
        var pushed: [String] { lock.withLock { pushes } }
        var peakConcurrency: Int { lock.withLock { maxConcurrent } }

        func fetchSnapshot(for mount: RemoteMountSpec) async throws -> [RemoteFileEntry] {
            let snapshot = lock.withLock { files }
            return snapshot.map { RemoteFileEntry(relativePath: $0.key, modificationTimestamp: 0, content: $0.value) }
        }

        func pushFile(content: String, relativePath: String, for mount: RemoteMountSpec) async throws -> TimeInterval {
            lock.withLock {
                concurrent += 1
                maxConcurrent = max(maxConcurrent, concurrent)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            lock.withLock {
                concurrent -= 1
                pushes.append(content)
                files[relativePath] = content
            }
            return Date().timeIntervalSince1970
        }

        func deleteFile(relativePath: String, for mount: RemoteMountSpec) async throws {}
    }

    private var tempDir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory("FolioDebounce")
        defaults = isolatedDefaults()
    }

    private func makeFile(_ name: String, _ content: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func diskText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testRapidEditsAreWrittenOnceAfterTheQuietPeriod() throws {
        let file = try makeFile("a.md", "start")
        let vm = makeIsolatedViewModel(defaults: defaults)
        vm.autoSaveDelay = 0.2
        vm.openFile(at: file)

        var text = "start"
        for i in 0..<10 {
            text += " \(i)"
            vm.handleEditorTextEdited(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        }
        XCTAssertEqual(try diskText(file), "start", "Typing must not rewrite the file on every keystroke")
        XCTAssertTrue(vm.isDirty)
        XCTAssertTrue(vm.hasPendingAutoSave)

        runLoop(for: 0.5)
        XCTAssertEqual(try diskText(file), text)
        XCTAssertFalse(vm.isDirty)
        XCTAssertEqual(vm.recentSelfWrites.count, 1, "Ten edits produce one write")
    }

    func testSwitchingFilesFlushesThePendingAutosave() throws {
        let fileA = try makeFile("a.md", "A")
        let fileB = try makeFile("b.md", "B")
        let vm = makeIsolatedViewModel(defaults: defaults)
        vm.autoSaveDelay = 5
        vm.openFile(at: fileA)
        vm.handleEditorTextEdited("A edited", selectedRange: NSRange(location: 8, length: 0))
        vm.openFile(at: fileB)
        XCTAssertEqual(try diskText(fileA), "A edited")
        XCTAssertFalse(vm.hasPendingAutoSave)
    }

    func testAppTerminationFlushesThePendingAutosave() throws {
        let file = try makeFile("a.md", "A")
        let vm = makeIsolatedViewModel(defaults: defaults)
        vm.autoSaveDelay = 5
        vm.openFile(at: file)
        vm.handleEditorTextEdited("A before quit", selectedRange: NSRange(location: 13, length: 0))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(try diskText(file), "A before quit")
    }

    func testManualSaveCancelsThePendingAutosave() throws {
        let file = try makeFile("a.md", "A")
        let vm = makeIsolatedViewModel(defaults: defaults)
        vm.autoSaveDelay = 5
        vm.openFile(at: file)
        vm.handleEditorTextEdited("A saved", selectedRange: NSRange(location: 7, length: 0))
        vm.saveDocument()
        XCTAssertEqual(try diskText(file), "A saved")
        XCTAssertFalse(vm.hasPendingAutoSave)
    }

    func testSelfWriteHistoryKeepsOnlyRecentDigests() {
        var history = SelfWriteHistory(capacity: 3)
        for i in 0..<5 { history.record("content \(i)") }
        XCTAssertEqual(history.count, 3)
        XCTAssertFalse(history.contains("content 0"))
        XCTAssertTrue(history.contains("content 4"))
        XCTAssertFalse(history.contains("never written"))
        history.removeAll()
        XCTAssertFalse(history.contains("content 4"))
    }

    func testRemoteUploadsDoNotOverlapAndTheLatestContentWins() async throws {
        let transport = RecordingTransport()
        let spec = try RemoteMountSpec.parse(connectionString: "gardener@example-host:/srv/notes", targetKind: .folder)
        transport.seed("plan.md", "v0")
        let mirror = tempDir.appendingPathComponent("Mirrors", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        let manager = RemoteWorkspaceManager(transport: transport, mirrorBaseDirectory: mirror, userDefaults: defaults)
        manager.baseRetryDelaySeconds = 0.01
        let vm = EditorWorkspaceViewModel(remoteWorkspaceManager: manager)
        vm.autoSaveDelay = 0
        _ = await vm.connectRemoteMount(spec)
        let node = try XCTUnwrap(vm.flatMarkdownFiles.first(where: { $0.name == "plan.md" }))
        vm.openFile(at: node.url)

        let versions = (1...6).map { "v\($0)" }
        for version in versions {
            vm.handleEditorTextEdited(version, selectedRange: NSRange(location: 2, length: 0))
        }
        for _ in 0..<200 where transport.pushed.last != "v6" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(transport.pushed.last, "v6", "The newest content is uploaded last")
        XCTAssertEqual(transport.peakConcurrency, 1, "Uploads for one file never overlap")
        let order = transport.pushed.compactMap { versions.firstIndex(of: $0) }
        XCTAssertEqual(order, order.sorted(), "Uploads arrive in edit order")
        XCTAssertLessThan(transport.pushed.count, versions.count, "Queued intermediate versions are skipped")
    }
}
