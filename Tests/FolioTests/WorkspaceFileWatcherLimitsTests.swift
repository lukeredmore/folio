import Darwin
import XCTest
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

@MainActor
final class WorkspaceFileWatcherLimitsTests: XCTestCase {

    private func makeIsolatedViewModel(using hub: SharedDirectoryWatchHub) throws -> EditorWorkspaceViewModel {
        let resolvedDefaults = isolatedDefaults()
        let mirror = try makeTemporaryDirectory("WatcherLimitsMirror")
        let manager = RemoteWorkspaceManager(mirrorBaseDirectory: mirror, userDefaults: resolvedDefaults)
        let watcher = POSIXWorkspaceFileWatcher(directoryWatchHub: hub)
        let vm = EditorWorkspaceViewModel(
            remoteWorkspaceManager: manager,
            userDefaults: resolvedDefaults,
            workspaceFileWatcher: watcher
        )
        addTeardownBlock { @MainActor in
            vm.pendingAutoSaveWorkItem?.cancel()
            vm.pendingAutoSaveWorkItem = nil
            vm.stopWatchingCurrentFile()
            vm.stopWatchingWorkspaceFolders()
        }
        return vm
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    func testTargetSoftOpenFileLimitRaisesLaunchdDefaultAndRespectsBounds() {
        XCTAssertEqual(
            FolioProcessLimits.targetSoftOpenFileLimit(
                currentSoft: 256,
                hardLimit: FolioProcessLimits.rlimInfinity,
                kernelMaxPerProc: 245_760
            ),
            65_536
        )
        XCTAssertEqual(
            FolioProcessLimits.targetSoftOpenFileLimit(
                currentSoft: 256,
                hardLimit: 4_096,
                kernelMaxPerProc: 245_760
            ),
            4_096
        )
        XCTAssertEqual(
            FolioProcessLimits.targetSoftOpenFileLimit(
                currentSoft: 256,
                hardLimit: FolioProcessLimits.rlimInfinity,
                kernelMaxPerProc: 10_240
            ),
            10_240
        )
        XCTAssertNil(
            FolioProcessLimits.targetSoftOpenFileLimit(
                currentSoft: 1_048_575,
                hardLimit: FolioProcessLimits.rlimInfinity,
                kernelMaxPerProc: 245_760
            )
        )

        let effectiveLimit = FolioProcessLimits.raiseOpenFileLimitIfNeeded()
        XCTAssertGreaterThanOrEqual(effectiveLimit, Int(OPEN_MAX))
        XCTAssertGreaterThanOrEqual(FolioProcessLimits.currentSoftOpenFileLimit(), Int(OPEN_MAX))
    }

    func testMultipleWindowsWatchingSameFoldersShareSingleKernelDescriptors() throws {
        let root = try makeTemporaryDirectory("SharedWatchRoot")
        try "# Root\n".write(to: root.appendingPathComponent("root.md"), atomically: true, encoding: .utf8)
        var subfolders: [URL] = []
        for index in 0..<8 {
            let sub = root.appendingPathComponent("sub-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try "# Sub \(index)\n".write(to: sub.appendingPathComponent("doc-\(index).md"), atomically: true, encoding: .utf8)
            subfolders.append(sub)
        }

        let hub = SharedDirectoryWatchHub()
        var viewModels: [EditorWorkspaceViewModel] = []
        for _ in 0..<6 {
            let vm = try makeIsolatedViewModel(using: hub)
            vm.loadWorkspaceFolder(root)
            viewModels.append(vm)
        }

        XCTAssertEqual(hub.activeDescriptorCount, 9, "Six windows watching the same 9 directories must share 9 kernel descriptors")

        let newFile = subfolders[3].appendingPathComponent("added.md")
        try "# Added\n".write(to: newFile, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            waitUntil {
                viewModels.allSatisfy { vm in
                    vm.flatMarkdownFiles.contains(where: { $0.name == "added.md" })
                }
            },
            "All subscribing view models should receive updates from the shared directory watcher"
        )

        for index in 0..<5 {
            viewModels[index].removeLocalFolder(root)
        }
        XCTAssertEqual(hub.activeDescriptorCount, 9, "Descriptors stay open while one window still watches the folder")

        viewModels[5].removeLocalFolder(root)
        XCTAssertEqual(hub.activeDescriptorCount, 0, "Removing the last subscriber closes all shared directory descriptors")
    }

    func testBreadthFirstPriorityWatchesAllSidebarRootsWithinDirectoryCap() throws {
        let rootA = try makeTemporaryDirectory("BreadthRootA")
        try "# Root A\n".write(to: rootA.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        for index in 0..<30 {
            let child = rootA.appendingPathComponent(String(format: "dir-%02d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try "# Child \(index)\n".write(to: child.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        }

        let rootB = try makeTemporaryDirectory("BreadthRootB")
        try "# Root B\n".write(to: rootB.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let rootC = try makeTemporaryDirectory("BreadthRootC")
        try "# Root C\n".write(to: rootC.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)

        let hub = SharedDirectoryWatchHub(maxProcessDirectories: 20)
        let vm = try makeIsolatedViewModel(using: hub)
        vm.loadWorkspaceFolder(rootA)
        vm.loadWorkspaceFolder(rootB)
        vm.loadWorkspaceFolder(rootC)

        XCTAssertEqual(hub.activeDescriptorCount, 20)

        let expectedRootKeys = Set(
            [rootA, rootB, rootC].map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        )
        XCTAssertTrue(
            expectedRootKeys.isSubset(of: vm.folderWatchEntries),
            "All depth-0 sidebar roots must be watched before deeper subdirectories consume the budget"
        )

        let addedInC = rootC.appendingPathComponent("fresh-in-c.md")
        try "# Fresh C\n".write(to: addedInC, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            waitUntil { vm.flatMarkdownFiles.contains(where: { $0.name == "fresh-in-c.md" }) },
            "Watched later root C should still detect newly added files under a tight directory cap"
        )
    }

    func testLowDescriptorCeilingPreservesHeadroomAcrossLargeFolderTrees() throws {
        let root = try makeTemporaryDirectory("HeadroomRoot")
        try "# Root\n".write(to: root.appendingPathComponent("root.md"), atomically: true, encoding: .utf8)
        for index in 0..<40 {
            let child = root.appendingPathComponent(String(format: "dir-%02d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try "# Child \(index)\n".write(to: child.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        }

        let headroom = 128
        let budgetAboveBaseline = 15
        final class AtomicLimitBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage = 256
            var value: Int {
                get { lock.withLock { storage } }
                set { lock.withLock { storage = newValue } }
            }
        }
        let simulatedSoftLimit = AtomicLimitBox()
        let hub = SharedDirectoryWatchHub(
            maxProcessDirectories: 512,
            reservedDescriptorHeadroom: headroom,
            softOpenFileLimitProvider: { simulatedSoftLimit.value }
        )
        let vm = try makeIsolatedViewModel(using: hub)
        if let fallback = vm.workspaceFolderURL {
            vm.removeLocalFolder(fallback)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let probeFD = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(probeFD, 0)
        if probeFD >= 0 { close(probeFD) }
        simulatedSoftLimit.value = Int(probeFD) + headroom + budgetAboveBaseline

        vm.loadWorkspaceFolder(root)

        XCTAssertGreaterThanOrEqual(hub.activeDescriptorCount, 10)
        XCTAssertLessThanOrEqual(hub.activeDescriptorCount, budgetAboveBaseline)

        let postLoadFD = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(postLoadFD, 0)
        if postLoadFD >= 0 { close(postLoadFD) }
        XCTAssertLessThanOrEqual(
            Int(postLoadFD),
            Int(probeFD) + budgetAboveBaseline + 2,
            "Watcher descriptors must stay strictly below softLimit - reservedDescriptorHeadroom"
        )
    }

    func testHardDescriptorCeilingClosesDescriptorsAboveAllowedThreshold() throws {
        let folder = try makeTemporaryDirectory("HardCeilingFolder")
        let key = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let inode = POSIXWorkspaceFileWatcher.fileInode(for: folder)
        XCTAssertNotEqual(inode, 0)

        var dummyFDs: [Int32] = []
        defer {
            for fd in dummyFDs {
                close(fd)
            }
        }
        for _ in 0..<32 {
            let fd = open("/dev/null", O_RDONLY)
            guard fd >= 0 else { break }
            dummyFDs.append(fd)
            if fd >= 24 { break }
        }
        XCTAssertGreaterThanOrEqual(dummyFDs.last ?? -1, 20)

        let hub = SharedDirectoryWatchHub(
            maxProcessDirectories: 512,
            reservedDescriptorHeadroom: 128,
            softOpenFileLimitProvider: { 32 }
        )

        let baselineFD = dup(STDIN_FILENO)
        XCTAssertGreaterThanOrEqual(baselineFD, 0)
        if baselineFD >= 0 { close(baselineFD) }

        for _ in 0..<25 {
            let subscribed = hub.subscribe(
                watcherID: UUID(),
                key: key,
                url: folder,
                currentInode: inode,
                onChanged: {},
                onInvalidated: {}
            )
            XCTAssertFalse(subscribed, "Descriptors opened at or above the headroom ceiling must be rejected immediately")
        }

        XCTAssertEqual(hub.activeDescriptorCount, 0)
        let afterFD = dup(STDIN_FILENO)
        XCTAssertGreaterThanOrEqual(afterFD, 0)
        if afterFD >= 0 { close(afterFD) }
        XCTAssertLessThan(afterFD, baselineFD + 5, "Rejected descriptors must be closed without leaking")
    }
}
