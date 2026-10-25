import AppKit
import SwiftUI

struct SidebarArticleRow: View {
    let node: WorkspaceFileNode
    let isSelected: Bool
    let accentColor: Color
    let mountConnectionState: RemoteConnectionState?
    let liveSyncStatus: RemoteFileSyncStatus
    let onNewFileInDirectory: (URL) -> Void
    let onNewLaTeXFileInDirectory: (URL) -> Void
    let onSyncMount: (UUID) -> Void
    let onDisconnectMount: (UUID) -> Void
    let sshDisplayPath: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isRemote ? "network" : node.iconSystemName)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)

                if let conn = node.remoteConnectionString {
                    Text(conn)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(node.modificationDate, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            SidebarRemoteStatusBadge(
                node: node,
                accentColor: accentColor,
                mountConnectionState: mountConnectionState,
                liveSyncStatus: liveSyncStatus
            )
        }
        .padding(.vertical, 2)
        .contextMenu {
            SidebarNodeContextMenu(
                node: node,
                sshDisplayPath: sshDisplayPath,
                onNewFileInDirectory: onNewFileInDirectory,
                onNewLaTeXFileInDirectory: onNewLaTeXFileInDirectory,
                onSyncMount: onSyncMount,
                onDisconnectMount: onDisconnectMount
            )
        }
    }
}

struct SidebarFileRow: View {
    let node: WorkspaceFileNode
    let accentColor: Color
    let mountConnectionState: RemoteConnectionState?
    let liveSyncStatus: RemoteFileSyncStatus
    let onNewFileInDirectory: (URL) -> Void
    let onNewLaTeXFileInDirectory: (URL) -> Void
    let onSyncMount: (UUID) -> Void
    let onDisconnectMount: (UUID) -> Void
    let sshDisplayPath: String?

    private var iconName: String {
        if node.isDirectory {
            return node.isRemoteRoot ? "externaldrive.connected.to.line.below" : "folder"
        }
        return node.isRemoteRoot ? "network" : node.iconSystemName
    }

    var body: some View {
        HStack(spacing: 6) {
            Label(node.name, systemImage: iconName)
                .lineLimit(1)

            Spacer(minLength: 4)

            SidebarRemoteStatusBadge(
                node: node,
                accentColor: accentColor,
                mountConnectionState: mountConnectionState,
                liveSyncStatus: liveSyncStatus
            )
        }
        .tag(node.isDirectory ? Optional<URL>.none : Optional(node.url))
        .help(node.remoteConnectionString ?? node.url.path)
        .contextMenu {
            SidebarNodeContextMenu(
                node: node,
                sshDisplayPath: sshDisplayPath,
                onNewFileInDirectory: onNewFileInDirectory,
                onNewLaTeXFileInDirectory: onNewLaTeXFileInDirectory,
                onSyncMount: onSyncMount,
                onDisconnectMount: onDisconnectMount
            )
        }
    }
}

struct SidebarNodeContextMenu: View {
    let node: WorkspaceFileNode
    let sshDisplayPath: String?
    let onNewFileInDirectory: (URL) -> Void
    let onNewLaTeXFileInDirectory: (URL) -> Void
    let onSyncMount: (UUID) -> Void
    let onDisconnectMount: (UUID) -> Void

    var body: some View {
        if node.isDirectory {
            Button {
                onNewFileInDirectory(node.url)
            } label: {
                Label("New Markdown File (.md)", systemImage: "doc.badge.plus")
            }
            Button {
                onNewLaTeXFileInDirectory(node.url)
            } label: {
                Label("New LaTeX File (.tex)", systemImage: "function")
            }
            Divider()
        }
        if let mountID = node.remoteMountID {
            Button {
                onSyncMount(mountID)
            } label: {
                Label("Sync Remote Now", systemImage: "arrow.triangle.2.circlepath")
            }
            if let sshURI = sshDisplayPath {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sshURI, forType: .string)
                } label: {
                    Label("Copy SSH Path (\(sshURI))", systemImage: "doc.on.doc")
                }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            } label: {
                Label("Reveal Local Mirror in Finder", systemImage: "folder")
            }
            if node.isRemoteRoot {
                Divider()
                Button(role: .destructive) {
                    onDisconnectMount(mountID)
                } label: {
                    Label("Disconnect Remote", systemImage: "eject")
                }
            }
        } else {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }
}

struct SidebarRemoteStatusBadge: View {
    let node: WorkspaceFileNode
    let accentColor: Color
    let mountConnectionState: RemoteConnectionState?
    let liveSyncStatus: RemoteFileSyncStatus

    var body: some View {
        if node.isRemoteRoot, let state = mountConnectionState {
            switch state {
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(accentColor)
                    .help("Syncing with remote host…")
            case .reconnecting(let attempt, let err, _):
                HStack(spacing: 3) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.caption2)
                    Text("#\(attempt)")
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(.orange)
                .help("Connection interrupted (\(err)). Auto-reconnecting…")
            case .error(let err):
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Connection interrupted (\(err)). Auto-reconnecting…")
            case .connected:
                Circle()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: 6, height: 6)
                    .help("Remote SSH Connected")
            }
        } else if !node.isDirectory, node.isRemote {
            switch liveSyncStatus {
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(accentColor)
                    .help("Syncing to remote…")
            case .pendingUpload:
                Image(systemName: "arrow.up.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Saved locally — queued to sync automatically when connection resumes")
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(message)
            case .conflictResolved, .synced:
                EmptyView()
            }
        }
    }
}
