import AppKit
import SwiftUI

struct FolioAppCommands: Commands {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var updateManager: AppUpdateManager

    var body: some Commands {
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

        paragraphCommandMenu
        formatCommandMenu
        viewCommandGroup
        themesCommandMenu
    }
}
