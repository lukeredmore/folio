import AppKit
import SwiftUI

/// Context menu actions for a sidebar row.
struct SidebarNodeActions {
    let sshDisplayPath: String?
    let newFile: (URL) -> Void
    let newLaTeXFile: (URL) -> Void
    let syncMount: (UUID) -> Void
    let disconnectMount: (UUID) -> Void
    let removeLocalFolder: (URL) -> Void
    let deleteItem: (URL) -> Void
    let openInNewTab: (URL) -> Void
}

struct SidebarArticleRow: View {
    let node: WorkspaceFileNode
    let isSelected: Bool
    let accentColor: Color
    let mountConnectionState: RemoteConnectionState?
    let liveSyncStatus: RemoteFileSyncStatus
    let actions: SidebarNodeActions

    /// Fixed so names line up when icons differ in width.
    static let iconColumnWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.isRemote ? "network" : node.iconSystemName)
                .foregroundStyle(.secondary)
                .frame(width: Self.iconColumnWidth)

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
            SidebarNodeContextMenu(node: node, actions: actions)
        }
    }
}

struct SidebarFileRow: View {
    let node: WorkspaceFileNode
    let accentColor: Color
    let mountConnectionState: RemoteConnectionState?
    let liveSyncStatus: RemoteFileSyncStatus
    let actions: SidebarNodeActions

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
            SidebarNodeContextMenu(node: node, actions: actions)
        }
    }
}

struct SidebarNodeContextMenu: View {
    let node: WorkspaceFileNode
    let actions: SidebarNodeActions

    var body: some View {
        if !node.isDirectory {
            Button {
                actions.openInNewTab(node.url)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
            Divider()
        }
        if node.isDirectory {
            Button {
                actions.newFile(node.url)
            } label: {
                Label("New Markdown File (.md)", systemImage: "doc.badge.plus")
            }
            Button {
                actions.newLaTeXFile(node.url)
            } label: {
                Label("New LaTeX File (.tex)", systemImage: "function")
            }
            Divider()
        }
        if let mountID = node.remoteMountID {
            Button {
                actions.syncMount(mountID)
            } label: {
                Label("Sync Remote Now", systemImage: "arrow.triangle.2.circlepath")
            }
            if let sshURI = actions.sshDisplayPath {
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
                    actions.disconnectMount(mountID)
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
            if node.isLocalRoot {
                Divider()
                Button {
                    actions.removeLocalFolder(node.url)
                } label: {
                    Label("Remove from Sidebar", systemImage: "minus.circle")
                }
            }
        }
        if node.isDeletableFromSidebar {
            Divider()
            Button(role: .destructive) {
                actions.deleteItem(node.url)
            } label: {
                Label(node.isRemote ? "Delete from Remote…" : "Move to Trash", systemImage: "trash")
            }
        }
    }
}

/// One icon for a remote mount's connection state. The tooltip carries the detail.
struct RemoteConnectionStateIcon: View {
    let state: RemoteConnectionState
    let accentColor: Color

    var body: some View {
        switch state {
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(accentColor)
                .help(state.statusSummary)
        case .reconnecting(let attempt, _, _):
            HStack(spacing: 3) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.caption2)
                Text("#\(attempt)")
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(.orange)
            .help(state.statusSummary)
        case .error:
            Image(systemName: "wifi.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help(state.statusSummary)
        case .connected:
            Circle()
                .fill(Color.green.opacity(0.85))
                .frame(width: 6, height: 6)
                .help(state.statusSummary)
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
            RemoteConnectionStateIcon(state: state, accentColor: accentColor)
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
