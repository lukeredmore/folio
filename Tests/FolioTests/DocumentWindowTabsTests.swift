import AppKit
import XCTest
@testable import Folio
@testable import FolioEditor
@testable import FolioEditorTestSupport
@testable import FolioModels
@testable import FolioTestSupport
@testable import FolioWorkspace
@testable import FolioWorkspaceTestSupport

/// Each window or tab owns its own document, while preferences and undo history stay app-wide.
@MainActor
final class DocumentWindowTabsTests: XCTestCase {

    private struct Fixture {
        let defaults: UserDefaults
        let mirrorURL: URL
        let folderURL: URL
        let alphaURL: URL
        let betaURL: URL
    }

    private var currentFixture: Fixture?

    override func setUp() async throws {
        let defaults = isolatedDefaults()
        let mirrorURL = try makeTemporaryDirectory("FolioTabsMirror")
        let folderURL = try makeTemporaryDirectory("FolioTabs")
        let alphaURL = folderURL.appendingPathComponent("alpha.md")
        let betaURL = folderURL.appendingPathComponent("beta.md")
        try "# Alpha\n\nFirst.\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "# Beta\n\nSecond.\n".write(to: betaURL, atomically: true, encoding: .utf8)
        currentFixture = Fixture(
            defaults: defaults,
            mirrorURL: mirrorURL,
            folderURL: folderURL,
            alphaURL: alphaURL,
            betaURL: betaURL
        )
    }

    override func tearDown() async throws {
        currentFixture = nil
    }

    private func fixture() throws -> Fixture {
        try XCTUnwrap(currentFixture)
    }

    private func makeRegistry() throws -> DocumentWindowRegistry {
        let env = try fixture()
        let manager = RemoteWorkspaceManager(mirrorBaseDirectory: env.mirrorURL, userDefaults: env.defaults)
        let registry = DocumentWindowRegistry(userDefaults: env.defaults, remoteWorkspaceManager: manager)
        addTeardownBlock { @MainActor in
            for viewModel in registry.viewModels {
                viewModel.pendingAutoSaveWorkItem?.cancel()
                viewModel.pendingAutoSaveWorkItem = nil
                viewModel.stopWatchingCurrentFile()
                viewModel.stopWatchingWorkspaceFolders()
            }
        }
        return registry
    }

    func testFirstWindowRestoresGlobalSessionAndNewTabStartsUntitled() throws {
        let env = try fixture()
        let legacy = makeIsolatedViewModel(defaults: env.defaults)
        legacy.loadWorkspaceFolder(env.folderURL)
        legacy.openFile(at: env.alphaURL)

        let registry = try makeRegistry()
        let first = registry.makeViewModel(for: DocumentWindowValue())
        XCTAssertEqual(first.currentFileURL?.standardizedFileURL, env.alphaURL.standardizedFileURL)
        XCTAssertEqual(first.documentTitle, "alpha.md")

        let tab = registry.makeViewModel(for: DocumentWindowValue(initialWorkspaceURL: env.folderURL))
        XCTAssertNil(tab.currentFileURL, "A new tab must not reopen another window's document")
        XCTAssertEqual(tab.markdownText, EditorWorkspaceViewModel.untitledDocumentTemplate)
        XCTAssertEqual(tab.workspaceFolderURL?.standardizedFileURL, env.folderURL.standardizedFileURL)
    }

    func testNewTabOpensRequestedFileAndAddsItToRecents() throws {
        let env = try fixture()
        let registry = try makeRegistry()
        _ = registry.makeViewModel(for: DocumentWindowValue())
        let tab = registry.makeViewModel(for: DocumentWindowValue(initialFileURL: env.betaURL, initialWorkspaceURL: env.folderURL))
        XCTAssertEqual(tab.currentFileURL?.standardizedFileURL, env.betaURL.standardizedFileURL)
        XCTAssertTrue(tab.markdownText.contains("# Beta"))
        XCTAssertEqual(tab.documentTitle, "beta.md")
        XCTAssertEqual(tab.recentFileURLs.first?.standardizedFileURL, env.betaURL.standardizedFileURL)
    }

    func testEachWindowRestoresItsOwnDocumentAfterRelaunch() throws {
        let env = try fixture()
        let firstValue = DocumentWindowValue()
        let secondValue = DocumentWindowValue()
        do {
            let registry = try makeRegistry()
            let first = registry.makeViewModel(for: firstValue)
            let second = registry.makeViewModel(for: secondValue)
            first.openFile(at: env.alphaURL)
            second.openFile(at: env.betaURL)
        }

        let relaunched = try makeRegistry()
        let second = relaunched.makeViewModel(for: secondValue)
        let first = relaunched.makeViewModel(for: firstValue)
        XCTAssertEqual(first.currentFileURL?.standardizedFileURL, env.alphaURL.standardizedFileURL)
        XCTAssertEqual(second.currentFileURL?.standardizedFileURL, env.betaURL.standardizedFileURL)
    }

    func testUntitledBuffersStaySeparatePerWindow() throws {
        let firstValue = DocumentWindowValue()
        let secondValue = DocumentWindowValue()
        do {
            let registry = try makeRegistry()
            let first = registry.makeViewModel(for: firstValue)
            let second = registry.makeViewModel(for: secondValue)
            first.newDocument()
            first.markdownText = "# One\n"
            second.markdownText = "# Two\n"
            first.persistDocumentSessionState()
            second.persistDocumentSessionState()
        }

        let relaunched = try makeRegistry()
        XCTAssertEqual(relaunched.makeViewModel(for: firstValue).markdownText, "# One\n")
        XCTAssertEqual(relaunched.makeViewModel(for: secondValue).markdownText, "# Two\n")
    }

    func testClosingWindowDeletesItsSessionButQuittingKeepsIt() throws {
        let env = try fixture()
        let registry = try makeRegistry()
        let quitting = registry.makeViewModel(for: DocumentWindowValue())
        let closing = registry.makeViewModel(for: DocumentWindowValue())
        quitting.openFile(at: env.alphaURL)
        closing.openFile(at: env.betaURL)

        quitting.closeDocumentWindowSession(isTerminating: true)
        closing.closeDocumentWindowSession(isTerminating: false)

        let pathKey = EditorWorkspaceViewModel.currentFilePathDefaultsKey
        XCTAssertEqual(env.defaults.string(forKey: quitting.windowSessionKey(pathKey)), env.alphaURL.path)
        XCTAssertNil(env.defaults.string(forKey: closing.windowSessionKey(pathKey)))
        XCTAssertFalse(env.defaults.bool(forKey: closing.windowSessionKey(EditorWorkspaceViewModel.hasSavedDocumentSessionDefaultsKey)))
    }

    func testPreferencesChangedInOneWindowApplyToTheOthers() throws {
        let registry = try makeRegistry()
        let first = registry.makeViewModel(for: DocumentWindowValue())
        let second = registry.makeViewModel(for: DocumentWindowValue())

        first.sourceCodeMode = !second.sourceCodeMode
        first.spellCheckEnabled = !second.spellCheckEnabled
        first.sourceLineWidth = 64
        let otherTheme = try? XCTUnwrap(first.availableThemes.first { $0.id != first.theme.id })
        if let otherTheme { first.theme = otherTheme }

        XCTAssertEqual(second.sourceCodeMode, first.sourceCodeMode)
        XCTAssertEqual(second.spellCheckEnabled, first.spellCheckEnabled)
        XCTAssertEqual(second.sourceLineWidth, 64)
        XCTAssertEqual(second.theme.id, first.theme.id)
        XCTAssertEqual(second.typography, first.typography)
    }

    func testWindowsShareUndoHistoryAndRecentFiles() throws {
        let env = try fixture()
        let registry = try makeRegistry()
        let first = registry.makeViewModel(for: DocumentWindowValue())
        let second = registry.makeViewModel(for: DocumentWindowValue())
        XCTAssertTrue(first.undoTimelineStore === second.undoTimelineStore)

        first.openFile(at: env.alphaURL)
        first.markdownText = "# Alpha\n\nEdited in the first tab.\n"
        second.openFile(at: env.alphaURL)
        XCTAssertTrue(second.canUndo, "A file's undo history must follow it into another tab")
        XCTAssertEqual(second.recentFileURLs.first?.standardizedFileURL, env.alphaURL.standardizedFileURL)
    }

    func testSameFileInTwoTabsSyncsQuietlyOnSave() throws {
        let env = try fixture()
        let registry = try makeRegistry()
        let editing = registry.makeViewModel(for: DocumentWindowValue())
        let mirror = registry.makeViewModel(for: DocumentWindowValue())
        editing.autoSaveDelay = 0
        editing.openFile(at: env.alphaURL)
        mirror.openFile(at: env.alphaURL)
        let undoCountBefore = editing.currentUndoStack.count

        let edited = "# Alpha\n\nEdited in one tab.\n"
        editing.markdownText = edited

        XCTAssertEqual(try String(contentsOf: env.alphaURL, encoding: .utf8), edited)
        XCTAssertEqual(mirror.markdownText, edited, "The other tab must show the saved text")
        XCTAssertFalse(mirror.isDirty)
        XCTAssertNil(mirror.externalUpdateNotice, "A save from another tab is not an external update")
        XCTAssertNil(mirror.activeConflict)
        XCTAssertEqual(editing.currentUndoStack.count, undoCountBefore + 1, "Syncing must not add undo steps")
        XCTAssertEqual(mirror.currentUndoStack.count, undoCountBefore + 1)

        mirror.undo()
        XCTAssertEqual(mirror.markdownText, "# Alpha\n\nFirst.\n", "Undo in either tab walks the shared history")
    }

    func testTabWithUnsavedEditsMergesASaveFromAnotherTab() throws {
        let env = try fixture()
        try "# Alpha\n\nFirst.\n\nLast.\n".write(to: env.alphaURL, atomically: true, encoding: .utf8)
        let registry = try makeRegistry()
        let saving = registry.makeViewModel(for: DocumentWindowValue())
        let typing = registry.makeViewModel(for: DocumentWindowValue())
        saving.autoSaveDelay = 0
        typing.autoSaveDelay = 60
        saving.openFile(at: env.alphaURL)
        typing.openFile(at: env.alphaURL)

        typing.markdownText = "# Alpha\n\nFirst.\n\nLast, edited.\n"
        saving.markdownText = "# Alpha Renamed\n\nFirst.\n\nLast.\n"

        XCTAssertEqual(typing.markdownText, "# Alpha Renamed\n\nFirst.\n\nLast, edited.\n")
        XCTAssertNil(typing.activeConflict)
    }

    func testOpenInNewTabWithoutWindowsOpensInPlace() throws {
        let env = try fixture()
        let registry = try makeRegistry()
        let only = registry.makeViewModel(for: DocumentWindowValue())
        only.openFile(at: env.alphaURL)
        only.openInNewTab(env.betaURL)
        XCTAssertEqual(only.currentFileURL?.standardizedFileURL, env.betaURL.standardizedFileURL)
    }

    func testFilesOpenedBeforeAnyWindowWaitForTheFirstWindow() throws {
        let env = try fixture()
        let registry = try makeRegistry()
        registry.openPaths([env.betaURL.path])
        let first = registry.makeViewModel(for: DocumentWindowValue())
        XCTAssertNil(first.currentFileURL)

        XCTAssertTrue(registry.claimLaunchSetup(for: first))
        XCTAssertFalse(registry.claimLaunchSetup(for: first), "Launch setup runs once")
        XCTAssertTrue(registry.activeViewModel === first)
        XCTAssertEqual(first.currentFileURL?.standardizedFileURL, env.betaURL.standardizedFileURL)
    }
}
