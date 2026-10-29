import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Folio

/// Window that reports itself as key. The test process never runs `NSApp.run()`, so AppKit
/// cannot make any window key; this keeps key-window behavior (selection colors, focus) the same
/// as in the app.
final class EditorHarnessWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }

    /// Keeps the requested frame, so the editor has the same size on every screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the production `MainWindowView` in a real window with isolated defaults and a temporary
/// workspace, and drives it with real `NSEvent`s. See `EditorHarness+Input.swift`.
@MainActor
final class EditorHarness {
    struct WorkFingerprint: Equatable {
        let editor: EditorPerfCounters
        let workspace: WorkspacePerfCounters
        let objectWillChange: Int
        let textLength: Int
        let selection: NSRange
        let scrollOrigin: NSPoint
    }

    let workspace: PerfFixtures.Workspace
    let viewModel: EditorWorkspaceViewModel
    let window: EditorHarnessWindow
    let textView: HybridMarkdownTextView
    let stallMonitor = MainThreadStallMonitor()
    private(set) var objectWillChangeCount = 0
    private let defaultsSuiteName: String
    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []

    var coordinator: HybridMarkdownEditorRepresentable.Coordinator {
        guard let coordinator = textView.editorCoordinator else {
            preconditionFailure("HybridMarkdownTextView lost its coordinator")
        }
        return coordinator
    }

    var counters: EditorPerfCounters { coordinator.perfCounters }
    var workspaceCounters: WorkspacePerfCounters { viewModel.perfCounters }
    var text: String { textView.string }

    convenience init(lineCount: Int, size: NSSize = NSSize(width: 1500, height: 1000)) throws {
        try self.init(workspace: PerfFixtures.makeWorkspace(lineCount: lineCount), size: size)
    }

    /// Opens `workspace.fileURL`. The harness removes the workspace in `tearDown()`.
    init(workspace: PerfFixtures.Workspace, size: NSSize = NSSize(width: 1500, height: 1000)) throws {
        self.workspace = workspace
        defaultsSuiteName = "app.folio.tests.perf.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        viewModel = EditorWorkspaceViewModel(userDefaults: defaults)
        viewModel.openFolder(at: workspace.directory)
        viewModel.openFile(at: workspace.fileURL)

        window = EditorHarnessWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowView(viewModel: viewModel))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        textView = try XCTUnwrap(viewModel.activeTextView, "MainWindowView did not create the editor")
        // The system scroller style depends on the attached pointing devices. A legacy scroller
        // takes width from the text when it appears, so every machine uses one.
        textView.enclosingScrollView?.scrollerStyle = .legacy

        viewModel.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChangeCount += 1 }
            }
            .store(in: &cancellables)
        window.makeFirstResponder(textView)
        settle()
        stallMonitor.start()
    }

    func tearDown() {
        stallMonitor.stop()
        cancellables.removeAll()
        viewModel.pendingAutoSaveWorkItem?.cancel()
        viewModel.pendingAutoSaveWorkItem = nil
        window.orderOut(nil)
        window.contentView = nil
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        workspace.remove()
    }

    var fingerprint: WorkFingerprint {
        WorkFingerprint(
            editor: counters.withoutTimings,
            workspace: workspaceCounters,
            objectWillChange: objectWillChangeCount,
            textLength: (textView.string as NSString).length,
            selection: textView.selectedRange(),
            scrollOrigin: textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        )
    }

    /// A line in the middle of the document that holds a plain paragraph.
    var middleParagraphLine: Int {
        let lines = workspace.document.paragraphLines
        return lines[lines.count / 2]
    }

    func lineStart(_ line: Int) -> Int {
        let nsText = textView.string as NSString
        var location = 0
        for _ in 0..<line {
            location = NSMaxRange(nsText.lineRange(for: NSRange(location: location, length: 0)))
        }
        return location
    }

    /// Number of lines in the editor text.
    var lineCount: Int {
        text.components(separatedBy: "\n").count
    }

    /// Length of the run of non-blank lines that contains the zero-based `line`, counting one
    /// newline per line.
    func blockLength(containingLine line: Int) -> Int {
        let lines = text.components(separatedBy: "\n")
        var first = line
        let isBlank = { (index: Int) in lines[index].trimmingCharacters(in: .whitespaces).isEmpty }
        while first > 0 && !isBlank(first - 1) { first -= 1 }
        var last = line
        while last + 1 < lines.count && !isBlank(last + 1) { last += 1 }
        return lines[first...last].reduce(0) { $0 + ($1 as NSString).length + 1 }
    }

    func lineText(_ line: Int) -> String {
        let nsText = textView.string as NSString
        let range = nsText.lineRange(for: NSRange(location: lineStart(line), length: 0))
        return nsText.substring(with: range).trimmingCharacters(in: .newlines)
    }
}

extension EditorPerfCounters {
    /// The counts only, so run-loop stability checks ignore timing noise.
    var withoutTimings: EditorPerfCounters {
        var copy = self
        copy.phaseNanoseconds = [:]
        return copy
    }
}
