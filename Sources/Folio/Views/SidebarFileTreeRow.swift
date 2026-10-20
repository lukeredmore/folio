import AppKit
import SwiftUI

struct FileTreeNodeRow: View {
    let node: WorkspaceFileNode
    let level: Int
    @ObservedObject var viewModel: EditorWorkspaceViewModel
    @ObservedObject var remoteManager: RemoteWorkspaceManager

    private var isExpanded: Bool {
        viewModel.isDirectoryExpanded(node.url)
    }

    private var mountConnectionState: RemoteConnectionState? {
        guard let mountID = node.remoteMountID else { return nil }
        return remoteManager.connectionStates[mountID]
    }

    private var liveSyncStatus: RemoteFileSyncStatus {
        remoteManager.syncStatus(forLocalURL: node.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if node.isDirectory {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        viewModel.toggleDirectoryExpanded(node.url)
                    }
                } else {
                    viewModel.openFile(at: node.url)
                }
            } label: {
                HStack(spacing: 5) {
                    if node.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(viewModel.theme.secondaryTextColor)
                            .frame(width: 10)
                        Image(systemName: node.isRemoteRoot ? "externaldrive.connected.to.line.below.fill" : "folder.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(viewModel.theme.linkColor.opacity(0.85))
                    } else {
                        Spacer().frame(width: 10)
                        Image(systemName: node.isRemoteRoot ? "network" : (node.isMarkdownFile ? "doc.text.fill" : "doc"))
                            .font(.system(size: 11.5))
                            .foregroundColor(node.isMarkdownFile ? viewModel.theme.linkColor : viewModel.theme.secondaryTextColor)
                    }

                    Text(node.name)
                        .font(.system(size: 12, weight: viewModel.currentFileURL == node.url ? .semibold : .regular))
                        .foregroundColor(viewModel.theme.textColor)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    remoteBadgeView
                }
                .padding(.leading, CGFloat(level) * 12.0 + 4.0)
                .padding(.trailing, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(viewModel.currentFileURL == node.url ? viewModel.theme.linkColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(node.remoteConnectionString ?? node.url.path)
            .contextMenu {
                if node.isDirectory {
                    Button("New Markdown File") {
                        viewModel.createNewFileInWorkspace(in: node.url)
                    }
                    Divider()
                }
                if let mountID = node.remoteMountID {
                    Button("Sync Remote Now") {
                        Task {
                            await remoteManager.syncMount(id: mountID, isBackground: false)
                        }
                    }
                    if let sshURI = remoteManager.remoteSSHDisplayPath(forLocalURL: node.url) ?? node.remoteConnectionString {
                        Button("Copy SSH Path (\(sshURI))") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sshURI, forType: .string)
                        }
                    }
                    Button("Reveal Local Mirror in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                    if node.isRemoteRoot {
                        Divider()
                        Button("Disconnect Remote", role: .destructive) {
                            viewModel.disconnectRemoteMount(id: mountID)
                        }
                    }
                } else {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    }
                }
            }

            if node.isDirectory, isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeNodeRow(
                        node: child,
                        level: level + 1,
                        viewModel: viewModel,
                        remoteManager: remoteManager
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var remoteBadgeView: some View {
        if node.isRemoteRoot, let state = mountConnectionState {
            switch state {
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(viewModel.theme.linkColor)
                    .help("Syncing with remote host…")
            case .reconnecting(let attempt, let err, _):
                HStack(spacing: 3) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("#\(attempt)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.orange)
                .help("Connection interrupted (\(err)). Auto-reconnecting…")
            case .error(let err):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .help("Connection interrupted (\(err)). Auto-reconnecting…")
            case .connected:
                Circle()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .help("Connected & synced (\(node.remoteConnectionString ?? "SSH"))")
            }
        } else if !node.isDirectory, node.isRemote {
            switch liveSyncStatus {
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9.5))
                    .foregroundColor(viewModel.theme.linkColor)
                    .help("Syncing to remote…")
            case .pendingUpload:
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .help("Saved locally — queued to sync automatically when connection resumes")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .help(message)
            case .conflictResolved, .synced:
                EmptyView()
            }
        }
    }
}
