import AppKit
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel

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
        .navigationTitle(viewModel.documentTitle + (viewModel.isDirty ? " — Edited" : ""))
        .sheet(isPresented: $viewModel.showInsertTableSheet) {
            InsertTableModalView(viewModel: viewModel)
        }
    }
}

#if !OPENTYPE_NO_MAIN
@main
#endif
public struct OpenTypeApp: App {
    @StateObject private var viewModel = EditorWorkspaceViewModel()

    public init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    public var body: some Scene {
        WindowGroup("OpenType") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
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

                Divider()

                Button("Quick Open...") {
                    viewModel.quickOpenQuery = ""
                    viewModel.showQuickOpen.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    viewModel.saveDocument()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Save As...") {
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
                ForEach(EditorTheme.allCases) { themeOption in
                    Button {
                        viewModel.theme = themeOption
                    } label: {
                        if viewModel.theme == themeOption {
                            Text("✓ \(themeOption.rawValue)")
                        } else {
                            Text("   \(themeOption.rawValue)")
                        }
                    }
                }
            }
        }
    }
}
