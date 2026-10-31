import AppKit
import SwiftUI

public struct StatusBarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    private var documentTooltipText: String {
        if let fileURL = viewModel.currentFileURL {
            if let sshPath = remoteManager.remoteSSHDisplayPath(forLocalURL: fileURL) {
                return sshPath
            }
            return fileURL.path
        }
        return viewModel.documentTitle
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 10) {
                // Left: Icon-only mode & status controls
                Button {
                    viewModel.sourceCodeMode.toggle()
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(viewModel.sourceCodeMode ? viewModel.theme.linkColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(viewModel.sourceCodeMode ? "Exit Source Code Mode (Cmd+/)" : "Toggle Source Code Mode (Cmd+/)")

                Button {
                    viewModel.prettyModeEnabled.toggle()
                } label: {
                    Image(systemName: viewModel.prettyModeEnabled ? "sparkles" : "sparkles.rectangle.stack")
                        .foregroundStyle(viewModel.prettyModeEnabled && !viewModel.sourceCodeMode ? viewModel.theme.linkColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle Pretty Mode for Images, Mermaid, SVGs & Inline HTML (Cmd+Shift+\\)")

                if viewModel.focusMode {
                    Button {
                        viewModel.focusMode = false
                    } label: {
                        Image(systemName: "eye")
                            .foregroundStyle(viewModel.theme.linkColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Exit Focus Mode (Cmd+Shift+D)")
                }

                if viewModel.typewriterMode {
                    Button {
                        viewModel.typewriterMode = false
                    } label: {
                        Image(systemName: "align.vertical.center")
                            .foregroundStyle(viewModel.theme.linkColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Exit Typewriter Mode (Cmd+Shift+T)")
                }

                if let fileURL = viewModel.currentFileURL,
                    let mount = remoteManager.mount(forLocalURL: fileURL)
                {
                    remoteStatusIcon(for: fileURL, mount: mount)
                }

                documentPersistenceStatusIcon

                Spacer(minLength: 8)

                // Right: Undo/Redo, Settings (with Theme Picker inside), and Word Count
                HStack(spacing: 8) {
                    Button {
                        viewModel.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundStyle(viewModel.canUndo ? .secondary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.canUndo)
                    .help(viewModel.undoActionTitle + " (Cmd+Z)")

                    Button {
                        viewModel.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .foregroundStyle(viewModel.canRedo ? .secondary : .tertiary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.canRedo)
                    .help(viewModel.redoActionTitle + " (Cmd+Shift+Z)")
                }

                Button {
                    viewModel.showSettingsModal.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(viewModel.showSettingsModal ? viewModel.theme.linkColor : .secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $viewModel.showSettingsModal, arrowEdge: .top) {
                    EditorSettingsView(viewModel: viewModel)
                }
                .help("Theme, Typography & Editor Settings (Cmd+,)")

                Button {
                    viewModel.showWordCountPopover.toggle()
                } label: {
                    HStack(spacing: 3) {
                        if viewModel.stats.selectedWords > 0 {
                            Text("\(viewModel.stats.selectedWords) / \(viewModel.stats.words) Words")
                        } else {
                            Text("\(viewModel.stats.words) Words")
                        }
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(viewModel.showWordCountPopover ? viewModel.theme.linkColor : .secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $viewModel.showWordCountPopover, arrowEdge: .top) {
                    WordCountPopoverView(viewModel: viewModel)
                }
                .help("Word Count & Document Statistics")

                if !viewModel.selectionComments.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            viewModel.showCommentsSidebar.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble.fill")
                                .font(.system(size: 10.5))
                            Text("\(viewModel.selectionComments.count)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(viewModel.showCommentsSidebar ? viewModel.theme.linkColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Toggle Comments Sidebar")
                }
            }

            // Center: Current file name
            HStack(spacing: 5) {
                Text(viewModel.documentTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if viewModel.isDirty {
                    Circle()
                        .fill(viewModel.theme.linkColor)
                        .frame(width: 5, height: 5)
                        .help("Edited")
                }
            }
            .frame(maxWidth: 320)
            .allowsHitTesting(false)
            .help(documentTooltipText)
        }
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(viewModel.theme.editorBackgroundColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(viewModel.theme.borderColor)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var documentPersistenceStatusIcon: some View {
        if let conflict = viewModel.activeConflict {
            Button {
                viewModel.showConflictResolverModal = true
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .anchorPreference(key: AutosaveIndicatorAnchorKey.self, value: .bounds) { $0 }
            .help("Conflict (\(conflict.conflictHunks.count)) — Click to resolve")
        } else if let notice = viewModel.externalUpdateNotice {
            Button {
                viewModel.showExternalUpdateDiffModal = true
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .anchorPreference(key: AutosaveIndicatorAnchorKey.self, value: .bounds) { $0 }
            .help(
                (notice.wasThreeWayMerged
                    ? "Auto-Merged (+\(notice.addedLines)/-\(notice.removedLines))"
                    : "Updated Externally (+\(notice.addedLines)/-\(notice.removedLines))")
                    + " — Click to inspect diff or undo"
            )
        } else if viewModel.currentFileURL != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tertiary)
                .help("Auto-saved — All edits are automatically saved to disk and infinitely undoable")
        }
    }

    @ViewBuilder
    private func remoteStatusIcon(for fileURL: URL, mount: RemoteMountSpec) -> some View {
        let fileStatus = remoteManager.syncStatus(forLocalURL: fileURL)
        let mountState = remoteManager.connectionStates[mount.id] ?? .connected
        let sshLabel = remoteManager.remoteSSHDisplayPath(forLocalURL: fileURL) ?? mount.connectionString

        let (text, icon, color): (String, String, Color) = {
            switch (fileStatus, mountState) {
            case (.syncing, _), (_, .syncing):
                return ("Syncing \(mount.host)…", "arrow.triangle.2.circlepath", viewModel.theme.linkColor)
            case (.pendingUpload, _):
                return ("Queued for \(mount.host)", "arrow.up.circle.fill", .orange)
            case (_, .reconnecting(let attempt, _, _)):
                return ("Reconnecting \(mount.host) (#\(attempt))…", "wifi.exclamationmark", .orange)
            case (_, .error):
                return ("Offline (\(mount.host))", "wifi.exclamationmark", .orange)
            case (.error, _):
                return ("Sync Retry (\(mount.host))", "exclamationmark.triangle.fill", .orange)
            default:
                return ("SSH: \(mount.host)", "checkmark.icloud.fill", .green)
            }
        }()

        Button {
            Task {
                await remoteManager.syncMount(id: mount.id, isBackground: false)
            }
        } label: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .buttonStyle(.borderless)
        .help("\(text) (\(sshLabel)) — Click to sync now")
    }
}
