import AppKit
import SwiftUI

public struct StatusBarView: View {
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    public init(viewModel: EditorWorkspaceViewModel) {
        self.viewModel = viewModel
        self.remoteManager = viewModel.remoteWorkspaceManager
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Left: Sidebar toggle & Source Code Mode toggle
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    viewModel.showSidebar.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12.5))
                    .foregroundColor(viewModel.showSidebar ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (Cmd+Shift+L)")

            Button {
                viewModel.sourceCodeMode.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11.5))
                    if viewModel.sourceCodeMode {
                        Text("Exit Source Code Mode")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundColor(viewModel.sourceCodeMode ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Toggle Source Code Mode (Cmd+/)")

            Button {
                viewModel.prettyModeEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.prettyModeEnabled ? "sparkles" : "sparkles.rectangle.stack")
                        .font(.system(size: 11.5))
                    Text(viewModel.prettyModeEnabled ? "Pretty" : "Raw Media")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(viewModel.prettyModeEnabled && !viewModel.sourceCodeMode ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .help("Toggle Pretty Mode for Images, Mermaid, SVGs & Inline HTML (Cmd+Shift+\\)")

            // Active mode badges (Focus Mode / Typewriter Mode)
            if viewModel.focusMode {
                modeBadge(title: "Focus Mode", icon: "eye") {
                    viewModel.focusMode = false
                }
            }
            if viewModel.typewriterMode {
                modeBadge(title: "Typewriter", icon: "align.vertical.center") {
                    viewModel.typewriterMode = false
                }
            }

            if let fileURL = viewModel.currentFileURL,
               let mount = remoteManager.mount(forLocalURL: fileURL) {
                remoteStatusPill(for: fileURL, mount: mount)
            }

            documentPersistenceStatusPill

            Spacer()

            // Undo / Redo quick controls with infinite timeline depth
            HStack(spacing: 6) {
                Button {
                    viewModel.undo()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                        if !viewModel.currentUndoStack.isEmpty {
                            Text("\(viewModel.currentUndoStack.count)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundColor(viewModel.canUndo ? viewModel.theme.secondaryTextColor : viewModel.theme.secondaryTextColor.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canUndo)
                .help(viewModel.undoActionTitle + " (Cmd+Z)")

                Button {
                    viewModel.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(viewModel.canRedo ? viewModel.theme.secondaryTextColor : viewModel.theme.secondaryTextColor.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRedo)
                .help(viewModel.redoActionTitle + " (Cmd+Shift+Z)")
            }

            // Theme quick selector menu
            Menu {
                Section("Default Themes") {
                    ForEach(EditorTheme.builtInThemes) { themeOption in
                        Button {
                            viewModel.selectTheme(themeOption)
                        } label: {
                            HStack {
                                Text(themeOption.name)
                                if viewModel.theme.id == themeOption.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                if !viewModel.customThemes.isEmpty {
                    Section("Saved Themes") {
                        ForEach(viewModel.customThemes) { themeOption in
                            Button {
                                viewModel.selectTheme(themeOption)
                            } label: {
                                HStack {
                                    Text(themeOption.name)
                                    if viewModel.theme.id == themeOption.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Customize Theme…") {
                    viewModel.showSettingsModal = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11))
                    Text(viewModel.isCurrentThemeModified ? "\(viewModel.theme.name) *" : viewModel.theme.name)
                        .font(.system(size: 11))
                }
                .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch or Customize Theme")

            // Typography & Layout Settings button
            Button {
                viewModel.showSettingsModal.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text("Settings")
                        .font(.system(size: 11))
                }
                .foregroundColor(viewModel.showSettingsModal ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $viewModel.showSettingsModal, arrowEdge: .top) {
                EditorSettingsView(viewModel: viewModel)
            }
            .help("Theme, Typography & Editor Settings (Cmd+,)")

            // Right: Word Count Popover button
            Button {
                viewModel.showWordCountPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    if viewModel.stats.selectedWords > 0 {
                        Text("\(viewModel.stats.selectedWords) / \(viewModel.stats.words) Words")
                    } else {
                        Text("\(viewModel.stats.words) Words")
                    }
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9))
                }
                .font(.system(size: 11.5, weight: .regular))
                .monospacedDigit()
                .foregroundColor(viewModel.theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $viewModel.showWordCountPopover, arrowEdge: .top) {
                WordCountPopoverView(viewModel: viewModel)
            }
            .help("Word Count & Document Statistics")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(viewModel.theme.editorBackgroundColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(viewModel.theme.borderColor)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var documentPersistenceStatusPill: some View {
        if let conflict = viewModel.activeConflict {
            Button {
                viewModel.showConflictResolverModal = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Conflict (\(conflict.conflictHunks.count)) — Resolve…")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.16))
                )
            }
            .buttonStyle(.plain)
            .help("External file changes conflict with local edits — Click to resolve")
        } else if let notice = viewModel.externalUpdateNotice {
            Button {
                viewModel.showExternalUpdateDiffModal = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.system(size: 10))
                    Text(notice.wasThreeWayMerged ? "Auto-Merged (+\(notice.addedLines)/-\(notice.removedLines))" : "Updated Externally (+\(notice.addedLines)/-\(notice.removedLines))")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.green.opacity(0.14))
                )
            }
            .buttonStyle(.plain)
            .help("Click to inspect external diff or undo")
        } else if viewModel.currentFileURL != nil {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9.5))
                Text("Auto-saved")
                    .font(.system(size: 10.5, weight: .regular))
            }
            .foregroundColor(viewModel.theme.secondaryTextColor.opacity(0.8))
            .help("All edits are automatically saved to disk and infinitely undoable")
        }
    }

    private func modeBadge(title: String, icon: String, onDismiss: @escaping () -> Void) -> some View {
        Button(action: onDismiss) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(viewModel.theme.linkColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(viewModel.theme.linkColor.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func remoteStatusPill(for fileURL: URL, mount: RemoteMountSpec) -> some View {
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
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(text)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .help("\(sshLabel) — Click to sync now")
    }
}
