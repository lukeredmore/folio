import AppKit
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager = .shared

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if viewModel.showSidebar {
                    SidebarView(viewModel: viewModel)
                    Divider()
                        .overlay(viewModel.theme.borderColor)
                }

                VStack(spacing: 0) {
                    RemoteConnectionBannerView(viewModel: viewModel)

                    DocumentConflictBannerView(viewModel: viewModel)

                    ExternalUpdateBannerView(viewModel: viewModel)

                    if viewModel.showFindReplaceBar {
                        FindReplaceBannerView(viewModel: viewModel)
                    }

                    HybridMarkdownEditorRepresentable(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    StatusBarView(viewModel: viewModel)
                }
            }
            .background(viewModel.theme.editorBackgroundColor)

            // Floating Quick Open overlay (Cmd+P)
            if viewModel.showQuickOpen {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.showQuickOpen = false
                    }

                VStack {
                    QuickOpenModalView(viewModel: viewModel)
                        .padding(.top, 64)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .preferredColorScheme(viewModel.theme.colorScheme)
        .navigationTitle(viewModel.documentTitle + (viewModel.activeConflict != nil ? " — Conflict" : ""))
        .background(WindowStatePersistenceAccessor(userDefaults: viewModel.userDefaults))
        .sheet(isPresented: $viewModel.showInsertTableSheet) {
            InsertTableModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showAddRemoteModal) {
            AddRemoteMountModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showConflictResolverModal) {
            ConflictResolverModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showExternalUpdateDiffModal) {
            ExternalUpdateDiffModalView(viewModel: viewModel)
        }
        .sheet(isPresented: $updateManager.showUpdateSheet) {
            AppUpdateModalView(updateManager: updateManager)
        }
    }
}

private struct WindowStatePersistenceAccessor: NSViewRepresentable {
    let userDefaults: UserDefaults
    static let windowFrameDefaultsKey = "Folio.MainWindowFrame.v1"

    func makeCoordinator() -> Coordinator {
        Coordinator(userDefaults: userDefaults)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.attach(to: window)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private let userDefaults: UserDefaults
        private weak var attachedWindow: NSWindow?

        init(userDefaults: UserDefaults) {
            self.userDefaults = userDefaults
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            if let oldWindow = attachedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: oldWindow)
                NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: oldWindow)
            }
            attachedWindow = window

            window.setFrameAutosaveName("FolioMainWindow")
            if let savedFrameString = userDefaults.string(forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey) {
                let rect = NSRectFromString(savedFrameString)
                if rect.width >= 720, rect.height >= 480 {
                    window.setFrame(rect, display: true)
                }
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeFrame(_:)),
                name: NSWindow.didResizeNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeFrame(_:)),
                name: NSWindow.didMoveNotification,
                object: window
            )
        }

        @objc private func windowDidChangeFrame(_ notification: Notification) {
            guard let window = attachedWindow else { return }
            let frameString = NSStringFromRect(window.frame)
            userDefaults.set(frameString, forKey: WindowStatePersistenceAccessor.windowFrameDefaultsKey)
        }
    }
}

@MainActor
public final class FolioAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

#if !FOLIO_NO_MAIN
@main
#endif
public struct FolioApp: App {
    @NSApplicationDelegateAdaptor(FolioAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = EditorWorkspaceViewModel()
    @ObservedObject private var updateManager = AppUpdateManager.shared

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.applicationIconImage = FolioBrandIcon.makeCurrentAppIconImage(pixelSize: 512)
    }

    public var body: some Scene {
        WindowGroup("Folio") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    updateManager.checkForUpdatesOnLaunchIfNeeded()
                    viewModel.remoteWorkspaceManager.startBackgroundSyncLoop()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            // MARK: - Software Updates
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task {
                        await updateManager.checkForUpdates(userInitiated: true)
                    }
                }
            }

            // MARK: - App Settings (Cmd+,)
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    viewModel.showSettingsModal.toggle()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            // MARK: - File Menu
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    viewModel.newDocument()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open...") {
                    viewModel.openDocumentPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open Folder...") {
                    viewModel.openFolderPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Menu("Open Recent") {
                    if viewModel.recentFileURLs.isEmpty {
                        Text("No Recent Documents")
                    } else {
                        ForEach(viewModel.recentFileURLs, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                viewModel.openFile(at: url)
                            }
                        }
                        Divider()
                        Button("Clear Menu") {
                            viewModel.clearRecentFiles()
                        }
                    }
                }

                Button("Connect Remote Folder or File (SSH)...") {
                    viewModel.showAddRemoteModal = true
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Quick Open...") {
                    viewModel.quickOpenQuery = ""
                    viewModel.showQuickOpen.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {
                if viewModel.currentFileURL == nil {
                    Button("Save to File...") {
                        viewModel.saveDocumentAs()
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                } else {
                    Button("All Changes Auto-Saved") {}
                        .disabled(true)
                }

                Button("Save a Copy As...") {
                    viewModel.saveDocumentAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                Menu("Export") {
                    Button("HTML...") {
                        viewModel.exportToHTML()
                    }
                    Button("PDF / Print...") {
                        viewModel.exportToPDF()
                    }
                }
            }

            // MARK: - Infinite Undo / Redo Menu
            CommandGroup(replacing: .undoRedo) {
                Button(viewModel.undoActionTitle) {
                    viewModel.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!viewModel.canUndo)

                Button(viewModel.redoActionTitle) {
                    viewModel.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo)
            }

            // MARK: - Edit / Find Menu
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find and Replace...") {
                    viewModel.showFindReplaceBar.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("Find in Workspace...") {
                    viewModel.showSidebar = true
                    viewModel.activeSidebarTab = .search
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            // MARK: - Paragraph Menu
            CommandMenu("Paragraph") {
                Button("Heading 1") { viewModel.setHeadingLevel(1) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Heading 2") { viewModel.setHeadingLevel(2) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Heading 3") { viewModel.setHeadingLevel(3) }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Heading 4") { viewModel.setHeadingLevel(4) }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Heading 5") { viewModel.setHeadingLevel(5) }
                    .keyboardShortcut("5", modifiers: [.command])
                Button("Heading 6") { viewModel.setHeadingLevel(6) }
                    .keyboardShortcut("6", modifiers: [.command])

                Divider()

                Button("Paragraph") { viewModel.setHeadingLevel(0) }
                    .keyboardShortcut("0", modifiers: [.command])

                Divider()

                Button("Table...") {
                    viewModel.showInsertTableSheet = true
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Button("Code Fences") {
                    viewModel.insertCodeFence()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Math Block") {
                    viewModel.insertMathBlock()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Button("Mermaid Diagram") {
                    viewModel.insertMermaidBlock()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Button("SVG Block") {
                    viewModel.insertSVGBlock()
                }

                Button("Quote") {
                    viewModel.insertBlockquote()
                }
                .keyboardShortcut("q", modifiers: [.command, .option])

                Divider()

                Button("Ordered List") {
                    viewModel.insertOrderedList()
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("Unordered List") {
                    viewModel.insertUnorderedList()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])

                Button("Task List") {
                    viewModel.insertTaskList()
                }
                .keyboardShortcut("x", modifiers: [.command, .option])

                Divider()

                Button("Horizontal Line") {
                    viewModel.insertHorizontalRule()
                }
                .keyboardShortcut("-", modifiers: [.command, .option])

                Divider()

                Button("Reflow Paragraph") {
                    viewModel.reflowCurrentParagraph()
                }
                .keyboardShortcut("q", modifiers: [.control])

                Button("Reflow Document") {
                    viewModel.reflowDocument()
                }
            }

            // MARK: - Format Menu
            CommandMenu("Format") {
                Button("Strong (Bold)") {
                    viewModel.applyInlineFormatting(prefix: "**", suffix: "**", placeholder: "bold")
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Emphasis (Italic)") {
                    viewModel.applyInlineFormatting(prefix: "*", suffix: "*", placeholder: "italic")
                }
                .keyboardShortcut("i", modifiers: [.command])

                Button("Inline Code") {
                    viewModel.applyInlineFormatting(prefix: "`", suffix: "`", placeholder: "code")
                }
                .keyboardShortcut("`", modifiers: [.command])

                Button("Strikethrough") {
                    viewModel.applyInlineFormatting(prefix: "~~", suffix: "~~", placeholder: "strike")
                }
                .keyboardShortcut("`", modifiers: [.command, .shift])

                Button("Highlight") {
                    viewModel.applyInlineFormatting(prefix: "==", suffix: "==", placeholder: "highlight")
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Inline Math") {
                    viewModel.applyInlineFormatting(prefix: "$", suffix: "$", placeholder: "E=mc^2")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Button("Hyperlink") {
                    viewModel.applyInlineFormatting(prefix: "[", suffix: "](https://)", placeholder: "link")
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("Image") {
                    viewModel.applyInlineFormatting(prefix: "![", suffix: "](image.png)", placeholder: "alt")
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
            }

            // MARK: - View Menu
            CommandGroup(after: .sidebar) {
                Button(viewModel.showSidebar ? "Hide Sidebar" : "Show Sidebar") {
                    viewModel.showSidebar.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Outline") {
                    viewModel.showSidebar = true
                    viewModel.activeSidebarTab = .outline
                }
                .keyboardShortcut("1", modifiers: [.command, .control])

                Button("Articles (File List)") {
                    viewModel.showSidebar = true
                    viewModel.activeSidebarTab = .files
                    viewModel.fileDisplayStyle = .list
                }
                .keyboardShortcut("2", modifiers: [.command, .control])

                Button("File Tree") {
                    viewModel.showSidebar = true
                    viewModel.activeSidebarTab = .files
                    viewModel.fileDisplayStyle = .tree
                }
                .keyboardShortcut("3", modifiers: [.command, .control])

                Divider()

                Toggle("Pretty Mode (Render Media, Diagrams & HTML)", isOn: $viewModel.prettyModeEnabled)
                    .keyboardShortcut("\\", modifiers: [.command, .shift])

                Toggle("Source Code Mode", isOn: $viewModel.sourceCodeMode)
                    .keyboardShortcut("/", modifiers: [.command])

                Toggle("Focus Mode", isOn: $viewModel.focusMode)
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])

                Toggle("Typewriter Mode", isOn: $viewModel.typewriterMode)
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF9FunctionKey)!)), modifiers: [])

                Divider()

                Toggle("Word Count Popover", isOn: $viewModel.showWordCountPopover)
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // MARK: - Themes Menu
            CommandMenu("Themes") {
                ForEach(EditorTheme.builtInThemes) { themeOption in
                    Button {
                        viewModel.selectTheme(themeOption)
                    } label: {
                        if viewModel.theme.id == themeOption.id {
                            Text(viewModel.isCurrentThemeModified ? "✓ \(themeOption.name) (Edited)" : "✓ \(themeOption.name)")
                        } else {
                            Text("   \(themeOption.name)")
                        }
                    }
                }

                if !viewModel.customThemes.isEmpty {
                    Divider()
                    ForEach(viewModel.customThemes) { customTheme in
                        Button {
                            viewModel.selectTheme(customTheme)
                        } label: {
                            if viewModel.theme.id == customTheme.id {
                                Text(viewModel.isCurrentThemeModified ? "✓ \(customTheme.name) (Edited)" : "✓ \(customTheme.name)")
                            } else {
                                Text("   \(customTheme.name)")
                            }
                        }
                    }
                }

                Divider()

                Button("Customize Theme & Typography…") {
                    viewModel.showSettingsModal = true
                }

                if viewModel.isCurrentThemeModified {
                    Button("Reset Theme to Saved Defaults") {
                        viewModel.resetCurrentTheme()
                    }
                }

                Button("Reset Character & Spacing Defaults") {
                    viewModel.resetTypographyToDefaults()
                }
            }
        }
    }
}
