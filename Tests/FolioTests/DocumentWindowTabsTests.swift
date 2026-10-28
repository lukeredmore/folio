import AppKit
import XCTest
@testable import Folio

/// Each window or tab owns its own document, while preferences and undo history stay app-wide.
@MainActor
final class DocumentWindowTabsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var mirrorURL: URL!
    private var folderURL: URL!
    private var alphaURL: URL!
    private var betaURL: URL!

    override func setUp() async throws {
        defaults = isolatedDefaults()
        mirrorURL = try makeTemporaryDirectory("FolioTabsMirror")
        folderURL = try makeTemporaryDirectory("FolioTabs")
        alphaURL = folderURL.appendingPathComponent("alpha.md")
        betaURL = folderURL.appendingPathComponent("beta.md")
        try "# Alpha\n\nFirst.\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "# Beta\n\nSecond.\n".write(to: betaURL, atomically: true, encoding: .utf8)
    }

    private func makeRegistry() -> DocumentWindowRegistry {
        let manager = RemoteWorkspaceManager(mirrorBaseDirectory: mirrorURL, userDefaults: defaults)
        return DocumentWindowRegistry(userDefaults: defaults, remoteWorkspaceManager: manager)
    }

    func testFirstWindowRestoresGlobalSessionAndNewTabStartsUntitled() {
        let legacy = makeIsolatedViewModel(defaults: defaults)
        legacy.loadWorkspaceFolder(folderURL)
        legacy.openFile(at: alphaURL)

        let registry = makeRegistry()
        let first = registry.makeViewModel(for: DocumentWindowValue())
        XCTAssertEqual(first.currentFileURL?.standardizedFileURL, alphaURL.standardizedFileURL)
        XCTAssertEqual(first.documentTitle, "alpha.md")

        let tab = registry.makeViewModel(for: DocumentWindowValue(initialWorkspaceURL: folderURL))
        XCTAssertNil(tab.currentFileURL, "A new tab must not reopen another window's document")
        XCTAssertEqual(tab.markdownText, EditorWorkspaceViewModel.untitledDocumentTemplate)
        XCTAssertEqual(tab.workspaceFolderURL?.standardizedFileURL, folderURL.standardizedFileURL)
    }

    func testNewTabOpensRequestedFileAndAddsItToRecents() {
        let registry = makeRegistry()
        _ = registry.makeViewModel(for: DocumentWindowValue())
        let tab = registry.makeViewModel(for: DocumentWindowValue(initialFileURL: betaURL, initialWorkspaceURL: folderURL))
        XCTAssertEqual(tab.currentFileURL?.standardizedFileURL, betaURL.standardizedFileURL)
        XCTAssertTrue(tab.markdownText.contains("# Beta"))
        XCTAssertEqual(tab.documentTitle, "beta.md")
        XCTAssertEqual(tab.recentFileURLs.first?.standardizedFileURL, betaURL.standardizedFileURL)
    }

    func testEachWindowRestoresItsOwnDocumentAfterRelaunch() {
        let firstValue = DocumentWindowValue()
        let secondValue = DocumentWindowValue()
        do {
            let registry = makeRegistry()
            let first = registry.makeViewModel(for: firstValue)
            let second = registry.makeViewModel(for: secondValue)
            first.openFile(at: alphaURL)
            second.openFile(at: betaURL)
        }

        let relaunched = makeRegistry()
        let second = relaunched.makeViewModel(for: secondValue)
        let first = relaunched.makeViewModel(for: firstValue)
        XCTAssertEqual(first.currentFileURL?.standardizedFileURL, alphaURL.standardizedFileURL)
        XCTAssertEqual(second.currentFileURL?.standardizedFileURL, betaURL.standardizedFileURL)
    }

    func testUntitledBuffersStaySeparatePerWindow() {
        let firstValue = DocumentWindowValue()
        let secondValue = DocumentWindowValue()
        do {
            let registry = makeRegistry()
            let first = registry.makeViewModel(for: firstValue)
            let second = registry.makeViewModel(for: secondValue)
            first.newDocument()
            first.markdownText = "# One\n"
            second.markdownText = "# Two\n"
            first.persistDocumentSessionState()
            second.persistDocumentSessionState()
        }

        let relaunched = makeRegistry()
        XCTAssertEqual(relaunched.makeViewModel(for: firstValue).markdownText, "# One\n")
        XCTAssertEqual(relaunched.makeViewModel(for: secondValue).markdownText, "# Two\n")
    }

    func testClosingWindowDeletesItsSessionButQuittingKeepsIt() {
        let registry = makeRegistry()
        let quitting = registry.makeViewModel(for: DocumentWindowValue())
        let closing = registry.makeViewModel(for: DocumentWindowValue())
        quitting.openFile(at: alphaURL)
        closing.openFile(at: betaURL)

        quitting.closeDocumentWindowSession(isTerminating: true)
        closing.closeDocumentWindowSession(isTerminating: false)

        let pathKey = EditorWorkspaceViewModel.currentFilePathDefaultsKey
        XCTAssertEqual(defaults.string(forKey: quitting.windowSessionKey(pathKey)), alphaURL.path)
        XCTAssertNil(defaults.string(forKey: closing.windowSessionKey(pathKey)))
        XCTAssertFalse(defaults.bool(forKey: closing.windowSessionKey(EditorWorkspaceViewModel.hasSavedDocumentSessionDefaultsKey)))
    }

    func testPreferencesChangedInOneWindowApplyToTheOthers() {
        let registry = makeRegistry()
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

    func testWindowsShareUndoHistoryAndRecentFiles() {
        let registry = makeRegistry()
        let first = registry.makeViewModel(for: DocumentWindowValue())
        let second = registry.makeViewModel(for: DocumentWindowValue())
        XCTAssertTrue(first.undoTimelineStore === second.undoTimelineStore)

        first.openFile(at: alphaURL)
        first.markdownText = "# Alpha\n\nEdited in the first tab.\n"
        second.openFile(at: alphaURL)
        XCTAssertTrue(second.canUndo, "A file's undo history must follow it into another tab")
        XCTAssertEqual(second.recentFileURLs.first?.standardizedFileURL, alphaURL.standardizedFileURL)
    }

    func testSameFileInTwoTabsSyncsQuietlyOnSave() {
        let registry = makeRegistry()
        let editing = registry.makeViewModel(for: DocumentWindowValue())
        let mirror = registry.makeViewModel(for: DocumentWindowValue())
        editing.autoSaveDelay = 0
        editing.openFile(at: alphaURL)
        mirror.openFile(at: alphaURL)
        let undoCountBefore = editing.currentUndoStack.count

        let edited = "# Alpha\n\nEdited in one tab.\n"
        editing.markdownText = edited

        XCTAssertEqual(try String(contentsOf: alphaURL, encoding: .utf8), edited)
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
        try "# Alpha\n\nFirst.\n\nLast.\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        let registry = makeRegistry()
        let saving = registry.makeViewModel(for: DocumentWindowValue())
        let typing = registry.makeViewModel(for: DocumentWindowValue())
        saving.autoSaveDelay = 0
        typing.autoSaveDelay = 60
        saving.openFile(at: alphaURL)
        typing.openFile(at: alphaURL)

        typing.markdownText = "# Alpha\n\nFirst.\n\nLast, edited.\n"
        saving.markdownText = "# Alpha Renamed\n\nFirst.\n\nLast.\n"

        XCTAssertEqual(typing.markdownText, "# Alpha Renamed\n\nFirst.\n\nLast, edited.\n")
        XCTAssertNil(typing.activeConflict)
    }

    func testOpenInNewTabWithoutWindowsOpensInPlace() {
        let registry = makeRegistry()
        let only = registry.makeViewModel(for: DocumentWindowValue())
        only.openFile(at: alphaURL)
        only.openInNewTab(betaURL)
        XCTAssertEqual(only.currentFileURL?.standardizedFileURL, betaURL.standardizedFileURL)
    }

    func testFilesOpenedBeforeAnyWindowWaitForTheFirstWindow() throws {
        let registry = makeRegistry()
        registry.openPaths([betaURL.path])
        let first = registry.makeViewModel(for: DocumentWindowValue())
        XCTAssertNil(first.currentFileURL)

        XCTAssertTrue(registry.claimLaunchSetup(for: first))
        XCTAssertFalse(registry.claimLaunchSetup(for: first), "Launch setup runs once")
        XCTAssertTrue(registry.activeViewModel === first)
        XCTAssertEqual(first.currentFileURL?.standardizedFileURL, betaURL.standardizedFileURL)
    }
}
