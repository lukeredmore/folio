import AppKit
import SwiftUI

/// App menus. They act on the focused window, or on the last active window when no window is focused.
struct FolioCommands: Commands {
    @FocusedObject private var focusedViewModel: EditorWorkspaceViewModel?
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var registry: DocumentWindowRegistry
    @ObservedObject var updateManager: AppUpdateManager

    var body: some Commands {
        // Commands exist before any window, so they supply `openWindow` for files opened at launch.
        let _ = registry.openWindowAction = openWindow
        if let viewModel = focusedViewModel ?? registry.activeViewModel {
            FolioAppCommands(viewModel: viewModel, updateManager: updateManager)
        }
    }
}

struct FolioAppCommands: Commands {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager

    var body: some Commands {
        appCommandGroups
        fileCommandGroups
        editCommandGroups
        paragraphCommandMenu
        formatCommandMenu
        viewCommandGroup
        themesCommandMenu
    }

    @CommandsBuilder
    private var appCommandGroups: some Commands {
        // MARK: - Software Updates & CLI Installation
        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                Task {
                    await updateManager.checkForUpdates(userInitiated: true)
                }
            }

            Button("Install '\(FolioAppIdentity.current.cliCommandName)' Command in PATH...") {
                FolioCLIManager.shared.installCLIFromMenu()
            }
        }

        // MARK: - App Settings (Cmd+,)
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                viewModel.showSettingsModal.toggle()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }

    @CommandsBuilder
    private var fileCommandGroups: some Commands {
        // MARK: - File Menu
        CommandGroup(replacing: .newItem) {
            Button("New Markdown Document") {
                viewModel.newDocument()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("New LaTeX Document (.tex)") {
                viewModel.newLaTeXDocument()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Tab") {
                viewModel.openInNewTab(nil)
            }
            .keyboardShortcut("t", modifiers: [.command])

            Button("Open...") {
                viewModel.openDocumentPanel()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Button("Add Folder...") {
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

            Button("Connect Remote Folder (SSH)...") {
                viewModel.showAddRemoteModal = true
            }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])

            Divider()

            Button("Quick Open (Shift+Shift)...") {
                viewModel.toggleQuickOpen()
            }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                viewModel.printDocument()
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
    }

    @CommandsBuilder
    private var editCommandGroups: some Commands {
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
        CommandGroup(replacing: .textEditing) {
            Button("Add Comment on Selection…") {
                viewModel.beginCommentOnCurrentSelection()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(!viewModel.hasNonEmptySelectionForTooltip)

            Button("Copy Formatted") {
                viewModel.copySelectionFormatted()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!viewModel.hasNonEmptySelectionForTooltip)

            Button("Copy Raw Markdown") {
                viewModel.copySelectionRaw()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!viewModel.hasNonEmptySelectionForTooltip)

            Button("Copy All Selection Comments") {
                viewModel.copyAllSelectionComments()
            }
            .keyboardShortcut("c", modifiers: [.command, .control])
            .disabled(viewModel.selectionComments.isEmpty)

            Divider()

            Button("Find...") {
                viewModel.openDocumentFind(withReplace: false)
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Find and Replace...") {
                viewModel.openDocumentFind(withReplace: true)
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Find Next") {
                viewModel.findNextInDocument()
            }
            .keyboardShortcut("g", modifiers: [.command])

            Button("Find Previous") {
                viewModel.findPreviousInDocument()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Find in Files...") {
                viewModel.openWorkspaceSearch(withReplace: false)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Find and Replace in Files...") {
                viewModel.openWorkspaceSearch(withReplace: true)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
