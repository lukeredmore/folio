import AppKit
import SwiftUI

extension FolioAppCommands {

    // MARK: - Paragraph Menu
    @CommandsBuilder
    var paragraphCommandMenu: some Commands {
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
    }

    // MARK: - Format Menu
    @CommandsBuilder
    var formatCommandMenu: some Commands {
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
    }

    // MARK: - View Menu
    @CommandsBuilder
    var viewCommandGroup: some Commands {
        CommandGroup(replacing: .sidebar) {
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
    }

    // MARK: - Themes Menu
    @CommandsBuilder
    var themesCommandMenu: some Commands {
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
